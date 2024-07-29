#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

is_GPDB5() {
    local gphome=$1
    version=$(ssh cdw "$gphome"/bin/postgres --gp-version)
    [[ $version =~ ^"postgres (Greenplum Database) 5." ]]
}

is_GPDB6() {
    local gphome=$1
    version=$(ssh cdw "$gphome"/bin/postgres --gp-version)
    [[ $version =~ ^"postgres (Greenplum Database) 6." ]]
}

# set the database gucs
# 1. bytea_output: by default for bytea the output format is hex on GPDB 6,
#    so change it to escape to match GPDB 5 representation
configure_gpdb_gucs() {
    local gphome=$1
    ssh -n cdw "
        set -eux -o pipefail

        source ${gphome}/greenplum_path.sh
        export MASTER_DATA_DIRECTORY=/data/gpdata/coordinator/gpseg-1
        gpconfig -c bytea_output -v escape
        gpstop -u
"
}

dump_sql() {
    local port=$1
    local dumpfile=$2

    echo "Dumping cluster contents from port ${port} to ${dumpfile}..."

    ssh -n cdw "
        set -eux -o pipefail

        source ${GPHOME_TARGET}/greenplum_path.sh
        pg_dumpall -p ${port} -f '$dumpfile'
    "
}

compare_dumps() {
    local source_dump=$1
    local target_dump=$2

    echo "Comparing dumps at ${source_dump} and ${target_dump}..."

    pushd gpupgrade_src
        # 5 to 6 requires some massaging of the diff due to expected changes.
        if (( $FILTER_DIFF )); then
            go build ./ci/main/scripts/filters/filter
            scp ./filter ./ci/main/scripts/filters/"${DIFF_FILE}" cdw:/tmp

            # First filter out any algorithmically-fixable differences, then
            # patch out the remaining expected diffs explicitly. We patch with
            # --ignore-whitespace because the patches could have been created
            # with `diff --ignore-space-change` which can cause some hunks to
            # have missing whitespace diffs (this is actually a good thing to
            # lower patch size).
            ssh cdw "
                /tmp/filter -version=6 -inputFile='$target_dump' > '$target_dump.filtered'
                patch --ignore-whitespace -R '$target_dump.filtered' /tmp/${DIFF_FILE}
            "

            if [ $? -ne 0 ]; then
                echo "error: patching failed"
                exit 1
            fi

            target_dump="$target_dump.filtered"

            # Run the filter on the source dump
            ssh -n cdw "
                /tmp/filter -version=5 -inputFile='$source_dump' > '$source_dump.filtered'
            "

            source_dump="$source_dump.filtered"
        fi
    popd

    ssh -n cdw "
        diff -U3 --speed-large-files --ignore-space-change --ignore-blank-lines '$source_dump' '$target_dump'
    "
}

install_source_GPDB_rpm_and_symlink() {
    yum install -y rpm_gpdb_source/*.rpm

    version=$(rpm -q --qf '%{version}' "$SOURCE_PACKAGE" | tr _ -)
    ln -s /usr/local/greenplum-db-${version} "$GPHOME_SOURCE"

    chown -R gpadmin:gpadmin "$GPHOME_SOURCE"
    chown -R gpadmin:gpadmin /usr/local/greenplum-db-${version}
}

# XXX: Setup target cluster before sourcing greenplum_path otherwise there are
# yum errors due to python issues.
# XXX: When source equals target then yum will fail when trying to re-install.
install_target_GPDB_rpm_and_symlink() {
    if [ "$SOURCE_PACKAGE" != "$TARGET_PACKAGE" ]; then
        yum install -y rpm_gpdb_target/*.rpm
    fi

    version=$(rpm -q --qf '%{version}' "$TARGET_PACKAGE" | tr _ -)
    ln -s /usr/local/greenplum-db-${version} "$GPHOME_TARGET"

    chown -R gpadmin:gpadmin "$GPHOME_TARGET"
    chown -R gpadmin:gpadmin /usr/local/greenplum-db-${version}
}

create_source_cluster() {
    source "$GPHOME_SOURCE"/greenplum_path.sh

    chown -R gpadmin:gpadmin gpdb_src_source/gpAux/gpdemo
    su gpadmin -c "make -j $(nproc) -C gpdb_src_source/gpAux/gpdemo create-demo-cluster"
    source gpdb_src_source/gpAux/gpdemo/gpdemo-env.sh
}
