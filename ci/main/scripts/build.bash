#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

mkdir -p ~/.ssh
ssh-keyscan github.com > ~/.ssh/known_hosts
echo "${GIT_SSH_KEY}" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

cd gpupgrade_src
export GOFLAGS="-mod=readonly" # do not update dependencies during build
git fetch git@github.com:greenplum-db/gpdb.git --tags

make oss-rpm
ci/main/scripts/verify-rpm.bash gpupgrade-*.rpm "Open Source"
mv gpupgrade-*.rpm ../built_oss

make enterprise-rpm
ci/main/scripts/verify-rpm.bash gpupgrade-*.rpm "Enterprise"
mv gpupgrade-*.rpm ../built_enterprise

