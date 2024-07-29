#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

source gpupgrade_src/ci/main/scripts/environment.bash
source gpupgrade_src/ci/main/scripts/ci-helpers.bash
./ccp_src/scripts/setup_ssh_to_cluster.sh

MODE=${MODE:-"copy"}
FILTER_DIFF=${FILTER_DIFF:-0}
DIFF_FILE=${DIFF_FILE:-"icw.diff"}

echo "Copying extensions to the target cluster..."
scp postgis_gppkg_target/postgis*.gppkg gpadmin@cdw:/tmp/postgis_target.gppkg
scp madlib_gppkg_target/madlib*.gppkg gpadmin@cdw:/tmp/madlib_target.gppkg
scp plr_gppkg_target/plr*.gppkg gpadmin@cdw:/tmp/plr_target.gppkg
scp plcontainer_gppkg_target/*.gppkg gpadmin@cdw:/tmp/plcontainer_target.gppkg

# PXF SNAPSHOT builds are only available as an RPM inside a tar.gz
tar -xf pxf_rpm_target/pxf*.tar.gz --directory pxf_rpm_target --strip-components=1 --wildcards '*.rpm'

mapfile -t hosts < cluster_env_files/hostfile_all
for host in "${hosts[@]}"; do
    scp pxf_rpm_target/*.rpm "gpadmin@${host}":/tmp/pxf_target.rpm

    ssh -n "centos@${host}" "
        set -eux -o pipefail

        sudo rpm -ivh /tmp/pxf_target.rpm
        sudo chown -R gpadmin:gpadmin /usr/local/pxf*
    "
done

ssh -n cdw "
    set -eux -o pipefail
    export GPHOME=${GPHOME_SOURCE}
    export PXF_BASE=/home/gpadmin/pxf

    PGDATABASE=postgres /usr/local/pxf-gp5/bin/pxf-pre-gpupgrade
"

if ! is_GPDB5 ${GPHOME_SOURCE}; then
    echo "Configuring GUCs before dumping the source cluster..."
    configure_gpdb_gucs ${GPHOME_SOURCE}
fi

echo "Dumping the source cluster for comparing after upgrade..."
dump_sql $PGPORT /tmp/source.sql

echo "Performing gpupgrade..."
time ssh -n cdw "
    set -ex -o pipefail

    echo 'Running initialize to create target cluster....'
    echo 'Initialize expected to fail as target extension is not yet installed since target cluster is needed...'
    set +e
    gpupgrade initialize \
              --non-interactive \
              --target-gphome $GPHOME_TARGET \
              --source-gphome $GPHOME_SOURCE \
              --source-master-port $PGPORT \
              --mode $MODE \
              --temp-port-range 6020-6040 \
              --dynamic-library-path ${GPHOME_TARGET}/madlib/Current/ports/greenplum/6/lib:/usr/local/greenplum-db-text/lib/gpdb6:/usr/local/pxf-gp6/gpextable
    set -e

    # Remove the expected failure logs such that any legitimate errors can easily be identified.
    rm -rf /home/gpadmin/gpAdminLogs/gpupgrade/pg_upgrade/*

    echo 'Installing extensions on the target cluster...'
    source /usr/local/greenplum-db-target/greenplum_path.sh
    export MASTER_DATA_DIRECTORY=\$(gpupgrade config show --target-datadir)
    export PGPORT=\$(gpupgrade config show --target-port)

    gpstart -a

    gppkg -i /tmp/postgis_target.gppkg
    gppkg -i /tmp/madlib_target.gppkg
    gppkg -i /tmp/plr_target.gppkg
    gppkg -i /tmp/plcontainer_target.gppkg

    echo 'Initialize PXF on target cluster...'
    export PXF_BASE=/home/gpadmin/pxf

    /usr/local/pxf-gp6/bin/pxf cluster register

    # This is a band-aid workaround due to gptext tech debt that needs to be addressed.
    # Extension data belongs in the extension directory and 'not' in the server
    # data directories. Do not mix them!
    # Since these files are required by the gptext .so file they need to be in
    # the target cluster. Since gpupgrade initialize is re-run and idempotent
    # place them in the backup of the coordinator data directory.
    cp $MASTER_DATA_DIRECTORY/{gptext.conf,gptxtenvs.conf,zoo_cluster.conf} /data/gpdata/coordinator/.gpupgrade/coordinator-pre-upgrade-backup/

    gpstop -a

    echo 'Finishing the upgrade...'
    gpupgrade initialize \
              --non-interactive \
              --target-gphome $GPHOME_TARGET \
              --source-gphome $GPHOME_SOURCE \
              --source-master-port $PGPORT \
              --mode $MODE \
              --temp-port-range 6020-6040 \
              --dynamic-library-path ${GPHOME_TARGET}/madlib/Current/ports/greenplum/6/lib:/usr/local/greenplum-db-text/lib/gpdb6:/usr/local/pxf-gp6/gpextable

    gpupgrade execute --non-interactive --skip-pg-upgrade-checks
    gpupgrade finalize --non-interactive
"

if ! is_GPDB5 ${GPHOME_TARGET}; then
    echo "Configuring GUCs before dumping the target cluster..."
    configure_gpdb_gucs ${GPHOME_TARGET}
fi

echo "Dumping the target cluster..."
dump_sql ${PGPORT} /tmp/target.sql

echo "Comparing the source and target dumps..."
if ! compare_dumps /tmp/source.sql /tmp/target.sql; then
    echo "error: before and after dumps differ"
    exit 1
fi

echo "Applying post-upgrade extension fixups after comparing dumps..."
ssh -n cdw "
    set -eux -o pipefail

    source /usr/local/greenplum-db-target/greenplum_path.sh

    echo 'Dropping operator dependent objects in order to successfully drop and recreate postgis operators...'
    psql -v ON_ERROR_STOP=1 -d postgres -c 'DROP INDEX wmstest_geomidx CASCADE;'
    psql -v ON_ERROR_STOP=1 -d postgres -f /usr/local/greenplum-db-target/share/postgresql/contrib/postgis-*/postgis_enable_operators.sql

    echo 'Starting pxf...'
    export GPHOME=${GPHOME_TARGET}
    export PXF_BASE=/home/gpadmin/pxf

    PGDATABASE=postgres /usr/local/pxf-gp6/bin/pxf-post-gpupgrade

    /usr/local/pxf-gp6/bin/pxf cluster start
"

echo "Upgrade successful..."
