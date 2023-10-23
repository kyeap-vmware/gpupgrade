#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

function run_tests() {
    # Prevent write permission errors
    chown -R gpadmin:gpadmin gpupgrade_src
    chown -R gpadmin:gpadmin gpdb_src_source
    chown -R gpadmin:gpadmin gpdb_src_target
    su gpadmin -c '
        set -eux -o pipefail

        export TERM=linux
        export GOFLAGS="-mod=readonly" # do not update dependencies during build

        cd gpupgrade_src
        make
        make unit integration --keep-going
    '
}

main() {
    echo "Setting up gpadmin user..."
    ln -s gpdb_src_source gpdb_src
    ./gpdb_src_source/concourse/scripts/setup_gpadmin_user.bash "centos"

    echo "Running data migration scripts and tests..."
    run_tests
}

main
