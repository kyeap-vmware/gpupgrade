-- Copyright (c) 2017-2024 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

--------------------------------------------------------------------------------
-- Create and setup non-upgradeable objects
--------------------------------------------------------------------------------

DROP SCHEMA IF EXISTS removed_tables CASCADE;
CREATE SCHEMA removed_tables;
SET search_path to removed_tables;

CREATE VIEW v01 AS SELECT * from pg_partition;
CREATE VIEW v02 AS SELECT * from pg_partition_rule;
CREATE VIEW v03 AS SELECT * from pg_partition_encoding;
CREATE VIEW v04 AS (SELECT * from (select * from pg_partition_rule)sub);
CREATE VIEW v05 AS SELECT * from pg_partition_rule, pg_database;
CREATE VIEW v06 AS (WITH dep_rel_cte AS (SELECT * FROM pg_partition_rule) SELECT * FROM dep_rel_cte);
CREATE VIEW v07 AS SELECT relnatts FROM pg_class WHERE 0 < ALL (SELECT parnatts FROM pg_partition);

---------------------------------------------------------------------------------
--- Assert that pg_upgrade --check correctly detects the non-upgradeable objects
---------------------------------------------------------------------------------
!\retcode gpupgrade initialize --source-gphome="${GPHOME_SOURCE}" --target-gphome=${GPHOME_TARGET} --source-master-port=${PGPORT} --disk-free-ratio 0 --non-interactive;
! find $(ls -dt ~/gpAdminLogs/gpupgrade/pg_upgrade_*/ | head -1) -name "views_with_removed_tables.txt" -exec cat {} +;

---------------------------------------------------------------------------------
--- Cleanup
---------------------------------------------------------------------------------
DROP VIEW v07;
DROP VIEW v06;
DROP VIEW v05;
DROP VIEW v04;
DROP VIEW v03;
DROP VIEW v02;
DROP VIEW v01;
