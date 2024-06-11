-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- generates a script to drop partition indexes that do not correspond to unique or primary
-- constraints
-- cte to hold the oid from all the root and child partition table
WITH partitions (relid) AS (
  SELECT DISTINCT parrelid
  FROM pg_partition
  UNION ALL
  SELECT DISTINCT parchildrelid
  FROM pg_partition_rule
),
-- cte to hold the unique and primary key constraint on all the root and child partition table
part_constraint AS (
  SELECT
    conname,
    c.relname connrel,
    n.nspname relschema,
    cc.relname rel
  FROM pg_constraint con
  JOIN pg_depend ON (refclassid, classid, objsubid) = ('pg_constraint' :: regclass, 'pg_class' :: regclass, 0)
    AND refobjid = con.oid
    AND deptype = 'i'
    AND contype IN ('u', 'p')
  JOIN pg_class c ON objid = c.oid AND relkind = 'i'
  JOIN partitions ON con.conrelid = partitions.relid
  JOIN pg_class cc ON cc.oid = partitions.relid
  JOIN pg_namespace n ON (n.oid = cc.relnamespace)
)
  SELECT
$$-- TYPE: INDEX, SCHEMA: $$ || pg_catalog.quote_ident(n.nspname) || $$, TABLE: $$ || pg_catalog.quote_ident(c.relname) || $$, NAME: $$ || pg_catalog.quote_ident(i.relname) || $$
DROP INDEX IF EXISTS $$ || pg_catalog.quote_ident(n.nspname) ||'.'|| pg_catalog.quote_ident(i.relname) || $$;$$ as definition
  FROM pg_index x
  JOIN partitions p ON p.relid = x.indrelid
  JOIN pg_class c ON p.relid = c.oid
  JOIN pg_class i ON i.oid = x.indexrelid
  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_tablespace t ON t.oid = i.reltablespace
  WHERE c.relkind = 'r' :: "char" AND i.relkind = 'i' :: "char" AND (i.relname, n.nspname, c.relname) NOT IN (SELECT connrel, relschema, rel FROM part_constraint);
