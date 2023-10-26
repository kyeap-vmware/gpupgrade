#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

# NOTE: All these steps need to be done in the same task since each task is run
# in its own isolated container with no shared state. Thus, installing the RPM
# needs to be done in the same task/container as running the tests.

source gpupgrade_src/ci/main/scripts/environment.bash
source gpupgrade_src/ci/main/scripts/ci-helpers.bash

function run_migration_scripts_and_tests() {
    # Prevent write permission errors
    chown -R gpadmin:gpadmin gpupgrade_src
    chown -R gpadmin:gpadmin gpdb_src_source
    chown -R gpadmin:gpadmin gpdb_src_target
    su gpadmin -c '
        set -eux -o pipefail

        export TERM=linux
        export GOPATH=$HOME/go
        export PATH=$PATH:$GOPATH/bin
        export GOFLAGS="-mod=readonly" # do not update dependencies during build

        mkdir -p $GOPATH/bin
        cd gpupgrade_src
        make && make install

        gpupgrade generate --non-interactive --gphome "$GPHOME_SOURCE" --port "$PGPORT" --seed-dir ./data-migration-scripts --output-dir /home/gpadmin/gpupgrade
        gpupgrade apply    --non-interactive --gphome "$GPHOME_SOURCE" --port "$PGPORT" --input-dir /home/gpadmin/gpupgrade --phase initialize

        make acceptance --keep-going
    '
}

main() {
    echo "Setting up gpadmin user..."
    ln -s gpdb_src_source gpdb_src
    ./gpdb_src_source/concourse/scripts/setup_gpadmin_user.bash "centos"

    echo "Installing the source GPDB rpm and symlink..."
    install_source_GPDB_rpm_and_symlink

    echo "Installing the target GPDB rpm and symlink..."
    install_target_GPDB_rpm_and_symlink

    echo "Creating the source demo cluster..."
    create_source_cluster

    echo "Running data migration scripts and tests..."
    run_migration_scripts_and_tests
}

main
