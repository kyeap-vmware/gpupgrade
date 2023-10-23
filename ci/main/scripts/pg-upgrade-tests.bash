#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

# NOTE: All these steps need to be done in the same task since each task is run
# in its own isolated container with no shared state. Thus, installing the RPM,
# and making isolation2 needs to be done in the same task/container.

source gpupgrade_src/ci/main/scripts/environment.bash
source gpupgrade_src/ci/main/scripts/ci-helpers.bash

# Normally gpdb would be compiled using setup_configure_vars and configure. We
# copy and modify these functions here because they assume only one installed
# cluster and hardcode GPHOME to /usr/local/greenplum-db-devel and gpdb's repo
# name to gpdb_src. Alternatively, refactor common.bash to use $GPHOME.
# However, due to unforeseen consequences and stability concerns we cannot do
# that. The source and target pg_isolation2_regress are compiled and install in
# separate sessions to prevent environment variable mixing.
make_source_and_target_pg_isolation2_regress() {
    if source_not_GPDB5 && different_source_and_target_version; then
        bash -c '
            source gpupgrade_src/ci/main/scripts/environment.bash
            source gpupgrade_src/ci/main/scripts/ci-helpers.bash

            # configure source
            configure_source

            # install source pg_isolation2_regress
            source "${GPHOME_SOURCE}"/greenplum_path.sh
            make -j "$(nproc)" -C gpdb_src_source
            make -j "$(nproc)" -C gpdb_src_source/src/test/isolation2 install
        '
    fi

    bash -c '
        source gpupgrade_src/ci/main/scripts/environment.bash
        source gpupgrade_src/ci/main/scripts/ci-helpers.bash

        # configure target
        configure_target

        # install target pg_isolation2_regress
        source "${GPHOME_TARGET}"/greenplum_path.sh
        make -j "$(nproc)" -C gpdb_src_target
        make -j "$(nproc)" -C gpdb_src_target/src/test/isolation2 install
    '
}

run_pg_upgrade_tests() {
    # Prevent write permission errors
    chown -R gpadmin:gpadmin gpupgrade_src
    chown -R gpadmin:gpadmin gpdb_src_source
    chown -R gpadmin:gpadmin gpdb_src_target
    time su gpadmin -c '
        set -eux -o pipefail

        export TERM=linux
        export PATH=$PATH:/usr/local/go/bin
        export GOFLAGS="-mod=readonly" # do not update dependencies during build
        export ISOLATION2_PATH_SOURCE=$(readlink -e gpdb_src_source/src/test/isolation2)
        export ISOLATION2_PATH_TARGET=$(readlink -e gpdb_src_target/src/test/isolation2)

        cd gpupgrade_src
        make pg-upgrade-tests
    '
}

main() {
    echo "Installing gpupgrade rpm..."
    yum install -y enterprise_rpm/gpupgrade-*.rpm

    echo "Setting up gpadmin user..."
    ln -s gpdb_src_source gpdb_src
    ./gpdb_src_source/concourse/scripts/setup_gpadmin_user.bash "centos"

    echo "Installing the source GPDB rpm and symlink..."
    install_source_GPDB_rpm_and_symlink

    echo "Installing the target GPDB rpm and symlink..."
    install_target_GPDB_rpm_and_symlink

    echo "Making pg_isolation2_regress for source and target GPDB version..."
    make_source_and_target_pg_isolation2_regress

    echo "Creating the source demo cluster..."
    create_source_cluster

    echo "Running tests..."
    run_pg_upgrade_tests
}

main
