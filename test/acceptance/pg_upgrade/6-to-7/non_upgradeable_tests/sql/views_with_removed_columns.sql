-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- We have tables in the catalog that contain removed columns but aren't
-- removed themselves. Views that reference such columns error out during
-- schema restore, rendering them non-upgradeable. They must be dropped before
-- running an upgrade.

--------------------------------------------------------------------------------
-- Create and setup non-upgradeable objects
--------------------------------------------------------------------------------

-- Create views containing references to removed column replication_port in
-- various portions of a potential view query tree (such as subquery, join, CTE
-- etc) to ensure that check_node_removed_columns_walker correctly flags these
-- as non-upgradeable. Note that this is not an exhaustive list covering all
-- possible expression types.
-- GPDB6: pg_class contains removed column relstorage,
CREATE VIEW v1 AS SELECT * FROM pg_appendonly;
CREATE VIEW v2 AS SELECT * FROM pg_stat_replication;
CREATE VIEW v3 AS SELECT * FROM pg_am;

-- Create a view containing a reference to a removed column that is in the
-- gp_toolkit schema. The relations that belong in gp_toolkit do not have
-- static oids. gp_toolkit only looks like a catalog schema, it doesn't have
-- drop protections. When the relations in gp_toolkit are dropped and recreated
-- they will have new oids that are over 16384.

-- Recreate gp_resgroup_status_per_segment. View definition taken from
-- gp_toolkit.sql. the oid for gp_resgroup_status_per_segment should not
-- be 12495 after this.
DROP VIEW gp_toolkit.gp_resgroup_status_per_segment;
CREATE VIEW gp_toolkit.gp_resgroup_status_per_segment AS
    WITH s AS (
        SELECT
            rsgname
          , groupid
          , (json_each(cpu_usage)).key::smallint AS segment_id
          , (json_each(cpu_usage)).value AS cpu
          , (json_each(memory_usage)).value AS memory
        FROM gp_toolkit.gp_resgroup_status
    )
    SELECT
        s.rsgname
      , s.groupid
      , c.hostname
      , s.segment_id
      , sum((s.cpu                       )::text::numeric) AS cpu
      , sum((s.memory->'used'            )::text::integer) AS memory_used
      , sum((s.memory->'available'       )::text::integer) AS memory_available
      , sum((s.memory->'quota_used'      )::text::integer) AS memory_quota_used
      , sum((s.memory->'quota_available' )::text::integer) AS memory_quota_available
      , sum((s.memory->'shared_used'     )::text::integer) AS memory_shared_used
      , sum((s.memory->'shared_available')::text::integer) AS memory_shared_available
    FROM s
    INNER JOIN pg_catalog.gp_segment_configuration AS c
        ON s.segment_id = c.content
        AND c.role = 'p'
    GROUP BY
        s.rsgname
      , s.groupid
      , c.hostname
      , s.segment_id
    ;
GRANT SELECT ON gp_toolkit.gp_resgroup_status_per_segment TO public;

CREATE VIEW v4 AS SELECT * FROM gp_toolkit.gp_resgroup_status;

--------------------------------------------------------------------------------
-- Assert that pg_upgrade --check correctly detects the non-upgradeable objects
--------------------------------------------------------------------------------
!\retcode gpupgrade initialize --source-gphome="${GPHOME_SOURCE}" --target-gphome=${GPHOME_TARGET} --source-master-port=${PGPORT} --disk-free-ratio 0 --non-interactive;
! find $(ls -dt ~/gpAdminLogs/gpupgrade/pg_upgrade_*/ | head -1) -name "views_with_removed_columns.txt" -exec cat {} +;

--------------------------------------------------------------------------------
-- Workaround to unblock upgrade
--------------------------------------------------------------------------------
DROP VIEW v1;
DROP VIEW v2;
DROP VIEW v3;
DROP VIEW v4;

