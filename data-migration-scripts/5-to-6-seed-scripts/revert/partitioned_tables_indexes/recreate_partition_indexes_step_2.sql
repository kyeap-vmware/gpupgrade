-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- generates SQL statement to create indexes on child partition tables that do
-- not correspond to primary or unique constraints.
WITH child_partitions_using_tsquery AS (
  SELECT DISTINCT pr.parchildrelid oid
  FROM pg_partition_rule pr
  JOIN pg_class pc ON pr.parchildrelid = pc.oid
  JOIN pg_attribute a ON a.attrelid = pc.oid
  WHERE a.atttypid = 'pg_catalog.tsquery' :: pg_catalog.regtype
),
child_partitions (relid) AS (
  SELECT DISTINCT parchildrelid
  FROM pg_partition_rule
  WHERE parchildrelid NOT IN (SELECT oid FROM child_partitions_using_tsquery)
),
part_constraints AS (
  SELECT
    conname,
    c.relname conrel,
    n.nspname relschema,
    cc.relname rel
  FROM pg_constraint con
  JOIN pg_depend dep ON (dep.refclassid, dep.classid, dep.objsubid) = ('pg_constraint' :: regclass, 'pg_class' :: regclass, 0)
    AND dep.refobjid = con.oid
    AND dep.deptype = 'i'
    AND con.contype IN ('u', 'p')
  JOIN pg_class c ON dep.objid = c.oid AND c.relkind = 'i'
  JOIN child_partitions ON con.conrelid = child_partitions.relid
  JOIN pg_class cc ON cc.oid = con.conrelid
  JOIN pg_namespace n ON (n.oid = cc.relnamespace)
),
indexes AS (
  SELECT
    n.nspname AS schemaname,
    c.relname AS tablename,
    i.relname AS indexname,
    t.spcname AS tablespace,
    pg_get_indexdef(i.oid) AS indexdef
  FROM pg_index x
  JOIN child_partitions np on np.relid = x.indrelid
  JOIN pg_class c ON c.oid = x.indrelid
  JOIN pg_class i ON i.oid = x.indexrelid
  LEFT JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_tablespace t ON t.oid = i.reltablespace
  WHERE c.relkind = 'r' :: "char" AND i.relkind = 'i' :: "char"
)
  SELECT
'-- TYPE: INDEX, SCHEMA: ' || schemaname || ', TABLE: ' || tablename || ', NAME: ' || indexname || E'
DO $$ BEGIN IF NOT EXISTS ( SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE  c.relname = ''' || indexname ||
''' AND n.nspname = ''' || schemaname || ''' ) THEN ' || indexdef || '; END IF; END $$; ' || '' as definition
  FROM indexes
  WHERE
  (indexname, schemaname, tablename) NOT IN (SELECT conrel, relschema, rel FROM part_constraints);
