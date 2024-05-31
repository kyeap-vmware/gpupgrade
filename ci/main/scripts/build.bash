#!/bin/bash
# Copyright (c) 2017-2023 VMware, Inc. or its affiliates
# SPDX-License-Identifier: Apache-2.0

set -eux -o pipefail

cd gpupgrade_src
export GOFLAGS="-mod=readonly" # do not update dependencies during build

make oss-rpm
ci/main/scripts/verify-rpm.bash gpupgrade-*.rpm "Open Source"
mv gpupgrade-*.rpm ../built_oss

make enterprise-rpm
ci/main/scripts/verify-rpm.bash gpupgrade-*.rpm "Enterprise"
mv gpupgrade-*.rpm ../built_enterprise

