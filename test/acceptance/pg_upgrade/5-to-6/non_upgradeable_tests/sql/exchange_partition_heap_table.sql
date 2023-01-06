-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- GPDB5: Tables having columns that are arrays of partition tables are not
-- upgradeable. Such tables must be dropped before proceeding with the upgrade.

--------------------------------------------------------------------------------
-- Create and setup non-upgradeable objects
--------------------------------------------------------------------------------
CREATE TABLE table_part(a INT, b INT) DISTRIBUTED BY (a) PARTITION BY RANGE(b) (PARTITION part1 START(0) END(42));
CREATE TABLE replacement(LIKE table_part) DISTRIBUTED BY (a);
ALTER TABLE table_part EXCHANGE PARTITION part1 WITH TABLE replacement;
CREATE TABLE dependant(d table_part_1_prt_part1[]);

--------------------------------------------------------------------------------
-- Assert that pg_upgrade --check correctly detects the non-upgradeable objects
--------------------------------------------------------------------------------
!\retcode gpupgrade initialize --source-gphome="${GPHOME_SOURCE}" --target-gphome=${GPHOME_TARGET} --source-master-port=${PGPORT} --disk-free-ratio 0 --automatic;

--------------------------------------------------------------------------------
-- Workaround to unblock upgrade
--------------------------------------------------------------------------------
DROP TABLE dependant;
