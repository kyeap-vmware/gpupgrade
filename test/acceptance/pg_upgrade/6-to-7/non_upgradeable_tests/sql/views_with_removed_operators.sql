-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

--------------------------------------------------------------------------------
-- Create and setup non-upgradeable objects
--------------------------------------------------------------------------------

CREATE OR REPLACE VIEW view_with_int2vectoreq AS SELECT '1 2'::INT2VECTOR = '1 2'::INT2VECTOR;

---------------------------------------------------------------------------------
--- Assert that pg_upgrade --check correctly detects the non-upgradeable objects
---------------------------------------------------------------------------------
!\retcode gpupgrade initialize --source-gphome="${GPHOME_SOURCE}" --target-gphome=${GPHOME_TARGET} --source-master-port=${PGPORT} --disk-free-ratio 0 --non-interactive;
! cat ~/gpAdminLogs/gpupgrade/pg_upgrade/p-1/views_with_removed_operators.txt;

---------------------------------------------------------------------------------
--- Workaround to unblock upgrade
---------------------------------------------------------------------------------
DROP VIEW view_with_int2vectoreq;
