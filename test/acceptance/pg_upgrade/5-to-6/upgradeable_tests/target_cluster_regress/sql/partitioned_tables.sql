-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

--------------------------------------------------------------------------------
-- Tests to ensure that various flavors of partitioned tables are functional post-upgrade
--
-- Tests are inspired by:
-- gpdb/src/test/regress/sql/partition.sql
-- gpdb/src/test/regress/sql/partition_indexing.sql
--------------------------------------------------------------------------------

--------------------------------------------------------------------------------
-- Helper functions
--------------------------------------------------------------------------------
DROP FUNCTION IF EXISTS dependencies();
CREATE FUNCTION dependencies() RETURNS TABLE( depname NAME, classtype "char",
                                              refname NAME, refclasstype "char",
                                              deptype "char" )
  LANGUAGE SQL STABLE STRICT AS $fn$
WITH RECURSIVE
  w AS (
    SELECT classid::regclass,
           objid,
           objsubid,
           refclassid::regclass,
           refobjid,
           refobjsubid,
           deptype
    FROM pg_depend d
    WHERE classid IN ('pg_constraint'::regclass, 'pg_class'::regclass)
      AND (objid > 16384 OR refobjid > 16384)

    UNION

    SELECT d2.*
    FROM w
           INNER JOIN pg_depend d2
                      ON (w.refclassid, w.refobjid, w.refobjsubid) =
                         (d2.classid, d2.objid, d2.objsubid)
  )
SELECT COALESCE(con.conname, c.relname, t.typname, nsp.nspname)     AS depname,
       COALESCE(con.contype, c.relkind, '-') as classtype,
       COALESCE(con2.conname, c2.relname, t2.typname, nsp2.nspname) AS refname,
       COALESCE(con2.contype, c2.relkind, '-') as refclasstype,
       w.deptype
FROM w
       LEFT JOIN pg_constraint con
                 ON classid = 'pg_constraint'::regclass AND objid = con.oid
       LEFT JOIN pg_class c ON classid = 'pg_class'::regclass AND objid = c.oid
       LEFT JOIN pg_type t ON classid = 'pg_type'::regclass AND objid = t.oid
       LEFT JOIN pg_namespace nsp
                 ON classid = 'pg_namespace'::regclass AND objid = nsp.oid

       LEFT JOIN pg_constraint con2
                 ON refclassid = 'pg_constraint'::regclass AND
                    refobjid = con2.oid
       LEFT JOIN pg_class c2
                 ON refclassid = 'pg_class'::regclass AND refobjid = c2.oid
       LEFT JOIN pg_type t2
                 ON refclassid = 'pg_type'::regclass AND refobjid = t2.oid
       LEFT JOIN pg_namespace nsp2 ON refclassid = 'pg_namespace'::regclass AND
                                      refobjid = nsp2.oid
$fn$;

DROP FUNCTION IF EXISTS index_backed_constraints();
CREATE FUNCTION index_backed_constraints() RETURNS TABLE(table_name NAME, constraint_name NAME, index_name NAME, constraint_type char)
  LANGUAGE SQL STABLE STRICT AS $fn$
    SELECT
      c1.relname,
      con.conname,
      c2.relname,
      con.contype::char
    FROM
        pg_constraint con
    JOIN
        pg_class c1 ON c1.oid = con.conrelid
    JOIN
        pg_class c2 ON c2.oid = con.conindid
    WHERE
        con.contype != 'c'
    ORDER BY conrelid
$fn$;

DROP FUNCTION IF EXISTS root_partition_indexes();
CREATE FUNCTION root_partition_indexes() RETURNS TABLE(table_name NAME, index_name REGCLASS,indisvalid boolean, column_num smallint, column_name NAME)
  LANGUAGE SQL STABLE STRICT AS $fn$
  WITH indexes AS (
    SELECT *, unnest(indkey) AS column_num
    FROM pg_index
  )
  SELECT DISTINCT
  c.relname as table_name,
  indexrelid::regclass as index_name,
  indisvalid,
  column_num,
  a.attname
  FROM indexes pi
  JOIN pg_partition pp ON pi.indrelid = pp.parrelid
  JOIN pg_class c on c.oid=pi.indrelid
  JOIN pg_class pc ON pc.oid = pp.parrelid
  JOIN pg_attribute a on a.attrelid = pi.indrelid AND a.attnum = pi.column_num
  ORDER BY 1, 2, 4
$fn$;

DROP FUNCTION IF EXISTS child_partition_indexes();
CREATE FUNCTION child_partition_indexes() RETURNS TABLE(table_name NAME, index_name REGCLASS, indisvalid boolean, has_child boolean, column_num smallint, column_name NAME)
  LANGUAGE SQL STABLE STRICT AS $fn$
  WITH indexes AS (
    SELECT *, unnest(indkey) AS column_num
    FROM pg_index
  )
  SELECT DISTINCT
  c.relname as table_name,
  indexrelid::regclass as index_name,
  indisvalid,
  pc.relhassubclass as has_child,
  column_num,
  a.attname
  FROM indexes pi
  JOIN pg_partition_rule pp ON pi.indrelid=pp.parchildrelid
  JOIN pg_class c on c.oid=pi.indrelid
  JOIN pg_class pc ON pc.oid=pp.parchildrelid
  JOIN pg_attribute a on a.attrelid = pi.indrelid AND a.attnum = pi.column_num
  ORDER by 1, 2, 4, 5
$fn$;

--------------------------------------------------------------------------------
-- Use the indexes whenever possible
--------------------------------------------------------------------------------
SET enable_indexscan = true;
SET enable_bitmapscan = true;
SET enable_seqscan = false;
SET optimizer = off;

--------------------------------------------------------------------------------
-- AO PARTITIONED TABLE WITH MULTIPLE SEGFILES AND DELETED TUPLES
--------------------------------------------------------------------------------

EXPLAIN (COSTS OFF) SELECT * FROM p_ao_table_with_multiple_segfiles WHERE id = 1 ORDER BY 1;
SELECT * FROM p_ao_table_with_multiple_segfiles WHERE id = 1 ORDER BY 1;

EXPLAIN (COSTS OFF) SELECT * FROM p_ao_table_with_multiple_segfiles WHERE id = 2 AND name = 'Jane' ORDER BY 1;
SELECT * FROM p_ao_table_with_multiple_segfiles WHERE id = 2 AND name = 'Jane' ORDER BY 1;

--------------------------------------------------------------------------------
-- AOCO PARTITIONED TABLE WITH MULTIPLE SEGFILES AND DELETED TUPLES
--------------------------------------------------------------------------------

EXPLAIN (COSTS OFF) SELECT * FROM p_aoco_table_with_multiple_segfiles WHERE id = 1 ORDER BY 1;
SELECT * FROM p_aoco_table_with_multiple_segfiles WHERE id = 1 ORDER BY 1;

EXPLAIN (COSTS OFF) SELECT * FROM p_aoco_table_with_multiple_segfiles WHERE id = 2 AND name = 'Jane' ORDER BY 1;
SELECT * FROM p_aoco_table_with_multiple_segfiles WHERE id = 2 AND name = 'Jane' ORDER BY 1;

--------------------------------------------------------------------------------
-- POLYMORPHIC PARTITIONED TABLES
-- Test to ensure that partitioned polymorphic tables can be
-- upgraded. We create the tables with 2 heap, 1 AO, 1 AOCO, and 1
-- external partitions. The root partition of each table will be
-- either heap or AOCO.
--------------------------------------------------------------------------------

-- Show what the storage types of each partition are after upgrade
SELECT relname, relstorage FROM pg_class WHERE relname SIMILAR TO 'poly_(list|range)_partition_with_(heap|aoco)_root%' AND relkind IN ('r') ORDER BY relname;


--------------------------------------------------------------------------------
-- poly_range_partition_with_heap_root
--------------------------------------------------------------------------------
EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_heap_root ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_heap_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;

DELETE FROM poly_range_partition_with_heap_root WHERE b%2 = 0 AND b > 1;
UPDATE poly_range_partition_with_heap_root SET b = b - 1 WHERE b > 1;
INSERT INTO poly_range_partition_with_heap_root SELECT 100 + i, i FROM generate_series(2, 9)i;

EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_heap_root ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_heap_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;


--------------------------------------------------------------------------------
-- poly_range_partition_with_aoco_root
--------------------------------------------------------------------------------
EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_aoco_root ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_aoco_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_aoco_root WHERE a < 5 OR a > 105 ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_aoco_root WHERE a < 5 OR a > 105 ORDER BY 1,2;

DELETE FROM poly_range_partition_with_aoco_root WHERE b%2 = 0 AND b > 1;
UPDATE poly_range_partition_with_aoco_root SET b = b - 1 WHERE b > 1;
INSERT INTO poly_range_partition_with_aoco_root SELECT 100 + i, i FROM generate_series(2, 9)i;

EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_aoco_root ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_aoco_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_range_partition_with_aoco_root WHERE a < 5 OR a > 105 ORDER BY 1,2;
SELECT * FROM poly_range_partition_with_aoco_root WHERE a < 5 OR a > 105 ORDER BY 1,2;

--------------------------------------------------------------------------------
-- poly_list_partition_with_heap_root
--------------------------------------------------------------------------------
EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_heap_root ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_heap_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;

DELETE FROM poly_list_partition_with_heap_root WHERE b%2 = 0 AND b > 1;
UPDATE poly_list_partition_with_heap_root SET b = b - 1 WHERE b > 1;
INSERT INTO poly_list_partition_with_heap_root SELECT 100 + i, i FROM generate_series(2, 9)i;

EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_heap_root ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_heap_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_heap_root WHERE a < 5 ORDER BY 1,2;

--------------------------------------------------------------------------------
-- poly_list_partition_with_aoco_root
--------------------------------------------------------------------------------
EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_aoco_root ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_aoco_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_aoco_root WHERE a < 5 ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_aoco_root WHERE a < 5 ORDER BY 1,2;

DELETE FROM poly_list_partition_with_aoco_root WHERE b%2 = 0 AND b > 1;
UPDATE poly_list_partition_with_aoco_root SET b = b - 1 WHERE b > 1;
INSERT INTO poly_list_partition_with_aoco_root SELECT 100 + i, i FROM generate_series(2, 9)i;

EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_aoco_root ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_aoco_root ORDER BY 1,2;
EXPLAIN (COSTS OFF) SELECT * FROM poly_list_partition_with_aoco_root WHERE a < 5 ORDER BY 1,2;
SELECT * FROM poly_list_partition_with_aoco_root WHERE a < 5 ORDER BY 1,2;

--------------------------------------------------------------------------------
-- MISMATCHED AO PARTITIONED TABLE INDEXES
-- Test upgrade of an AO partition hierarchy having an index defined on the parent, that is
-- not defined on all of the members of the hierarchy.
--------------------------------------------------------------------------------

SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'mismatched_aopartition_indexes%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'mismatched_aopartition_indexes%';

EXPLAIN (COSTS OFF) SELECT * FROM mismatched_aopartition_indexes ORDER BY 1;
SELECT * FROM mismatched_aopartition_indexes ORDER BY 1;
EXPLAIN (COSTS OFF) SELECT * FROM mismatched_aopartition_indexes WHERE b = 'apple' ORDER BY 1;
SELECT * FROM mismatched_aopartition_indexes WHERE b = 'apple' ORDER BY 1;

--------------------------------------------------------------------------------
-- PARTITIONED TABLES USING KEYWORDS
-- Ensure that partition names having keywords (reserved, non-reserved and
-- unclassified) can be upgraded by quoting them using the quote_all_identifiers
-- GUC.
--------------------------------------------------------------------------------

EXPLAIN (COSTS OFF) SELECT * FROM t_quote_test WHERE a < 5 ORDER BY 1;
SELECT * FROM t_quote_test WHERE a < 5 ORDER BY 1;

EXPLAIN (COSTS OFF) SELECT * FROM t_quote_test WHERE e = 'val10' ORDER BY 1;
SELECT * FROM t_quote_test WHERE e = 'val10' ORDER BY 1;

--------------------------------------------------------------------------------
-- PARTITION CHILDREN IN DIFFERENT SCHEMAS
--------------------------------------------------------------------------------

-- check data integrity after upgrade
SELECT * FROM public.different_schema_ptable ORDER BY 1, 2;
SELECT * FROM schema1.different_schema_ptable_1_prt_1 ORDER BY 1, 2;
SELECT * FROM schema2.different_schema_ptable_1_prt_2 ORDER BY 1, 2;
SELECT * FROM public.different_schema_ptable_1_prt_3 ORDER BY 1, 2;

-- check partition schemas
SELECT nsp.nspname, c.relname FROM pg_class c JOIN pg_namespace nsp ON nsp.oid = c.relnamespace WHERE relname LIKE 'different_schema_ptable%' ORDER BY relname;

-- test table insert
INSERT INTO public.different_schema_ptable SELECT i, i + 2 FROM generate_series(1, 3) i;

-- check data after insert
SELECT * FROM public.different_schema_ptable ORDER BY 1, 2;
SELECT * FROM schema1.different_schema_ptable_1_prt_1 ORDER BY 1, 2;
SELECT * FROM schema2.different_schema_ptable_1_prt_2 ORDER BY 1, 2;
SELECT * FROM public.different_schema_ptable_1_prt_3 ORDER BY 1, 2;

--- validate the indexes
EXPLAIN (COSTS OFF) SELECT * FROM public.different_schema_ptable WHERE b < 3 ORDER BY 1, 2;
SELECT * FROM public.different_schema_ptable WHERE b < 3 ORDER BY 1, 2;
EXPLAIN (COSTS OFF) SELECT * FROM schema1.different_schema_ptable_1_prt_1 WHERE b = 2 ORDER BY 1, 2;
SELECT * FROM schema1.different_schema_ptable_1_prt_1 WHERE b = 2 ORDER BY 1, 2;
EXPLAIN (COSTS OFF) SELECT * FROM schema2.different_schema_ptable_1_prt_2 WHERE b = 4 ORDER BY 1, 2;
SELECT * FROM schema2.different_schema_ptable_1_prt_2 WHERE b = 4 ORDER BY 1, 2;
EXPLAIN (COSTS OFF) SELECT * FROM public.different_schema_ptable_1_prt_3 WHERE b = 5 ORDER BY 1, 2;
SELECT * FROM public.different_schema_ptable_1_prt_3 WHERE b = 5 ORDER BY 1, 2;

--------------------------------------------------------------------------------
-- MULTILEVEL PARTITION CHILDREN IN DIFFERENT SCHEMAS
--------------------------------------------------------------------------------

-- check data integrity after upgrade
SELECT * FROM public.multilevel_different_schema_ptable ORDER BY 1, 2, 3;
SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_boys ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_1 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_2 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_3 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls ORDER BY 1, 2, 3;
SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_girls_2_prt_1 ORDER BY 1, 2, 3;
SELECT * FROM schema2.multilevel_different_schema_ptable_1_prt_girls_2_prt_2 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls_2_prt_3 ORDER BY 1, 2, 3;

-- check partition schemas
SELECT nsp.nspname, c.relname FROM pg_class c JOIN pg_namespace nsp ON nsp.oid = c.relnamespace WHERE relname LIKE 'multilevel_different_schema_ptable%' ORDER BY relname;

-- test table insert
INSERT INTO public.multilevel_different_schema_ptable VALUES (7, date '2001-01-15', 'M');
INSERT INTO public.multilevel_different_schema_ptable VALUES (8, date '2002-02-15', 'M');
INSERT INTO public.multilevel_different_schema_ptable VALUES (9, date '2003-03-15', 'M');
INSERT INTO public.multilevel_different_schema_ptable VALUES (10, date '2001-01-15', 'F');
INSERT INTO public.multilevel_different_schema_ptable VALUES (11, date '2002-02-15', 'F');
INSERT INTO public.multilevel_different_schema_ptable VALUES (12, date '2003-03-15', 'F');

-- check data after insert
SELECT * FROM public.multilevel_different_schema_ptable ORDER BY 1, 2, 3;
SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_boys ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_1 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_2 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_3 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls ORDER BY 1, 2, 3;
SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_girls_2_prt_1 ORDER BY 1, 2, 3;
SELECT * FROM schema2.multilevel_different_schema_ptable_1_prt_girls_2_prt_2 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls_2_prt_3 ORDER BY 1, 2, 3;

--- validate the indexes
EXPLAIN (COSTS OFF) SELECT * FROM public.multilevel_different_schema_ptable WHERE id = 3 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable WHERE id = 6 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_boys WHERE id = 7 ORDER BY 1, 2, 3;
SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_boys WHERE id = 7 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_2 WHERE id = 8 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_2 WHERE id = 8 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_3 WHERE id = 9 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_boys_2_prt_3 WHERE id = 9 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls WHERE id = 10 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls WHERE id = 10 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_girls_2_prt_1 WHERE id = 10 ORDER BY 1, 2, 3;
SELECT * FROM schema1.multilevel_different_schema_ptable_1_prt_girls_2_prt_1 WHERE id = 10 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM schema2.multilevel_different_schema_ptable_1_prt_girls_2_prt_2 WHERE id = 11 ORDER BY 1, 2, 3;
SELECT * FROM schema2.multilevel_different_schema_ptable_1_prt_girls_2_prt_2 WHERE id = 11 ORDER BY 1, 2, 3;

EXPLAIN (COSTS OFF) SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls_2_prt_3 WHERE id = 12 ORDER BY 1, 2, 3;
SELECT * FROM public.multilevel_different_schema_ptable_1_prt_girls_2_prt_3 WHERE id = 12 ORDER BY 1, 2, 3;

--------------------------------------------------------------------------------
-- PARTITION INDEX INHERITANCE TESTS
-- Ensure that partitioned index hierarchies are correctly established post-upgrade
--------------------------------------------------------------------------------

-- pt_inh_t1
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_inh_t1%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_inh_t1%';
SELECT * FROM dependencies() WHERE classtype = 'i' AND (depname LIKE '%inh_t1%' OR refname LIKE '%inh_t1%') ORDER BY depname, refname;

DROP INDEX pt_inh_t1_idx;

SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_inh_t1%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_inh_t1%';
SELECT * FROM dependencies() WHERE classtype = 'i' AND (depname LIKE '%inh_t1%' OR refname LIKE '%inh_t1%') ORDER BY depname, refname;

-- pt_inh_t2
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_inh_t2%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_inh_t2%';
SELECT * FROM dependencies() WHERE classtype = 'i' AND (depname LIKE '%inh_t2%' OR refname LIKE '%inh_t2%') ORDER BY depname, refname;

DROP INDEX pt_inh_t2_idx;

SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_inh_t2%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_inh_t2%';
SELECT * FROM dependencies() WHERE classtype = 'i' AND (depname LIKE '%inh_t2%' OR refname LIKE '%inh_t2%') ORDER BY depname, refname;

--------------------------------------------------------------------------------
-- HEAP PARTITIONED TABLE INDEXES
--------------------------------------------------------------------------------

-- pt_heap_unique1_uniqueidx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique1 < 10 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique1 < 10 ORDER BY 1;

-- pt_heap_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique2 < 10 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique2 < 10 ORDER BY 1;

-- pt_heap_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique1 < 10 and unique2 < 15 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique1 < 10 and unique2 < 15 ORDER BY 1;

-- pt_heap_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE two = 1 and four = 3 ORDER BY 1;
SELECT * FROM pt_heap WHERE two = 1 and four = 3 ORDER BY 1;

-- pt_heap_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE stringu2 = 'WAAAAA' and string4 = 'OOOOxx' ORDER BY 1;
SELECT * FROM pt_heap WHERE stringu2 = 'WAAAAA' and string4 = 'OOOOxx' ORDER BY 1;

-- pt_heap_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE ten = 9 and twenty = 19 ORDER BY 1;
SELECT * FROM pt_heap WHERE ten = 9 and twenty = 19 ORDER BY 1;

-- Validate that inserts are working after upgrade
insert into pt_heap values (0,20,1,3,7,18,4,34,156,301,11,17,'GFABCD','PPAVxx','HJKFxx');

-- pt_heap_unique1_uniqueidx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique1 = 0 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique1 = 0 ORDER BY 1;

-- pt_heap_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique2 = 20 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique2 = 20 ORDER BY 1;

-- pt_heap_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique1 = 0 and unique2 = 20 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique1 = 0 and unique2 = 20 ORDER BY 1;

-- pt_heap_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE two = 1 and four = 3 ORDER BY 1;
SELECT * FROM pt_heap WHERE two = 1 and four = 3 ORDER BY 1;

-- pt_heap_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE ten = 7 and twenty = 18 ORDER BY 1;
SELECT * FROM pt_heap WHERE ten = 7 and twenty = 18 ORDER BY 1;

-- pt_heap_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE string4 = 'HJKFxx' ORDER BY 1;
SELECT * FROM pt_heap WHERE string4 = 'HJKFxx' ORDER BY 1;

-- pt_heap_dropped_root_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE hundred = 4 ORDER BY 1;
SELECT * FROM pt_heap WHERE hundred=4 ORDER BY 1;

-- pt_heap_mid_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap_1_prt_part1 WHERE twothousand = 156 ORDER BY 1;
SELECT * FROM pt_heap_1_prt_part1 WHERE twothousand = 156 ORDER BY 1;

-- pt_heap_leaf_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE fivethous = 301 ORDER BY 1;
SELECT * FROM pt_heap WHERE fivethous=301 ORDER BY 1;

-- pt_heap_exchange1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE stringu1 = 'GFABCD' ORDER BY 1;
SELECT * FROM pt_heap WHERE stringu1 = 'GFABCD' ORDER BY 1;

-- Validate that updates are working after upgrade

UPDATE pt_heap SET unique1 = 1 WHERE unique1 = 0;
UPDATE pt_heap SET unique2 = 19 WHERE unique2 = 20;
UPDATE pt_heap SET two = 2, four = 4 WHERE two = 1 and four = 3;
UPDATE pt_heap SET ten = 2, twenty = 12 WHERE ten = 7 and twenty = 18;
UPDATE pt_heap SET string4 = 'HJKFyy' WHERE string4 = 'HJKFxx';
UPDATE pt_heap SET hundred = 8 WHERE hundred = 4;
UPDATE pt_heap SET twothousand = 199 WHERE twothousand = 156;
UPDATE pt_heap SET fivethous = 417 WHERE fivethous = 301;
UPDATE pt_heap SET stringu1 = 'ABCDEF' WHERE stringu1 = 'GFABCD';

-- pt_heap_unique1_uniqueidx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique1 = 1 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique1 = 1 ORDER BY 1;

-- pt_heap_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique2 = 19 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique2 = 19 ORDER BY 1;

-- pt_heap_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE unique1 = 1 and unique2 = 19 ORDER BY 1;
SELECT * FROM pt_heap WHERE unique1 = 1 and unique2 = 19 ORDER BY 1;

-- pt_heap_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE two = 2 and four = 4 ORDER BY 1;
SELECT * FROM pt_heap WHERE two = 2 and four = 4 ORDER BY 1;

-- pt_heap_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE ten = 2 and twenty = 12 ORDER BY 1;
SELECT * FROM pt_heap WHERE ten = 2 and twenty = 12 ORDER BY 1;

-- pt_heap_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE string4 = 'HJKFyy' ORDER BY 1;
SELECT * FROM pt_heap WHERE string4 = 'HJKFyy' ORDER BY 1;

-- pt_heap_dropped_root_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE hundred = 8 ORDER BY 1;
SELECT * FROM pt_heap WHERE hundred=8 ORDER BY 1;

-- pt_heap_mid_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap_1_prt_part1 WHERE twothousand = 199 ORDER BY 1;
SELECT * FROM pt_heap_1_prt_part1 WHERE twothousand = 199 ORDER BY 1;

-- pt_heap_leaf_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE fivethous = 417 ORDER BY 1;
SELECT * FROM pt_heap WHERE fivethous=417 ORDER BY 1;

-- pt_heap_exchange1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_heap WHERE stringu1 = 'ABCDEF' ORDER BY 1;
SELECT * FROM pt_heap WHERE stringu1 = 'ABCDEF' ORDER BY 1;

--------------------------------------------------------------------------------
-- AO PARTITIONED TABLE INDEXES
--------------------------------------------------------------------------------

-- pt_ao_unique1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique1 < 10 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique1 < 10 ORDER BY 1;

-- pt_ao_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique2 < 10 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique2 < 10 ORDER BY 1;

-- pt_ao_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique1 < 10 and unique2 < 15 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique1 < 10 and unique2 < 15 ORDER BY 1;

-- pt_ao_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE two = 1 and four = 3 ORDER BY 1;
SELECT * FROM pt_ao WHERE two = 1 and four = 3 ORDER BY 1;

-- pt_ao_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE stringu2 = 'WAAAAA' and string4 = 'OOOOxx' ORDER BY 1;
SELECT * FROM pt_ao WHERE stringu2 = 'WAAAAA' and string4 = 'OOOOxx' ORDER BY 1;

-- pt_ao_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE ten = 9 and twenty = 19 ORDER BY 1;
SELECT * FROM pt_ao WHERE ten = 9 and twenty = 19 ORDER BY 1;

-- Validate that inserts are working after upgrade
insert into pt_ao values (0,20,1,3,7,18,4,34,156,301,11,17,'GFABCD','PPAVxx','HJKFxx');

-- pt_ao_unique1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique1 = 0 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique1 = 0 ORDER BY 1;

-- pt_ao_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique2 = 20 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique2 = 20 ORDER BY 1;

-- pt_ao_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique1 = 0 and unique2 = 20 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique1 = 0 and unique2 = 20;

-- pt_ao_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE two = 1 and four = 3 ORDER BY 1;
SELECT * FROM pt_ao WHERE two = 1 and four = 3 ORDER BY 1;

-- pt_ao_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE ten = 7 and twenty = 18 ORDER BY 1;
SELECT * FROM pt_ao WHERE ten = 7 and twenty = 18 ORDER BY 1;

-- pt_ao_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE string4 = 'HJKFxx' ORDER BY 1;
SELECT * FROM pt_ao WHERE string4 = 'HJKFxx' ORDER BY 1;

-- pt_ao_dropped_root_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE hundred = 4 ORDER BY 1;
SELECT * FROM pt_ao WHERE hundred=4 ORDER BY 1;

-- pt_ao_mid_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao_1_prt_part1 WHERE twothousand = 156 ORDER BY 1;
SELECT * FROM pt_ao_1_prt_part1 WHERE twothousand = 156 ORDER BY 1;

-- pt_ao_leaf_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE fivethous = 301 ORDER BY 1;
SELECT * FROM pt_ao WHERE fivethous=301 ORDER BY 1;

-- pt_ao_exchange1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE stringu1 = 'GFABCD' ORDER BY 1;
SELECT * FROM pt_ao WHERE stringu1 = 'GFABCD' ORDER BY 1;

-- Validate that updates are working after upgrade

UPDATE pt_ao SET unique1 = 1 WHERE unique1 = 0;
UPDATE pt_ao SET unique2 = 19 WHERE unique2 = 20;
UPDATE pt_ao SET two = 2, four = 4 WHERE two = 1 and four = 3;
UPDATE pt_ao SET ten = 2, twenty = 12 WHERE ten = 7 and twenty = 18;
UPDATE pt_ao SET string4 = 'HJKFyy' WHERE string4 = 'HJKFxx';
UPDATE pt_ao SET hundred = 8 WHERE hundred = 4;
UPDATE pt_ao SET twothousand = 199 WHERE twothousand = 156;
UPDATE pt_ao SET fivethous = 417 WHERE fivethous = 301;
UPDATE pt_ao SET stringu1 = 'ABCDEF' WHERE stringu1 = 'GFABCD';

-- pt_ao_unique1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique1 = 1 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique1 = 1 ORDER BY 1;

-- pt_ao_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique2 = 19 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique2 = 19 ORDER BY 1;

-- pt_ao_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE unique1 = 1 and unique2 = 19 ORDER BY 1;
SELECT * FROM pt_ao WHERE unique1 = 1 and unique2 = 19 ORDER BY 1;

-- pt_ao_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE two = 2 and four = 4 ORDER BY 1;
SELECT * FROM pt_ao WHERE two = 2 and four = 4 ORDER BY 1;

-- pt_ao_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE ten = 2 and twenty = 12 ORDER BY 1;
SELECT * FROM pt_ao WHERE ten = 2 and twenty = 12 ORDER BY 1;

-- pt_ao_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE string4 = 'HJKFyy' ORDER BY 1;
SELECT * FROM pt_ao WHERE string4 = 'HJKFyy' ORDER BY 1;

-- pt_ao_dropped_root_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE hundred = 8 ORDER BY 1;
SELECT * FROM pt_ao WHERE hundred=8 ORDER BY 1;

-- pt_ao_mid_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao_1_prt_part1 WHERE twothousand = 199 ORDER BY 1;
SELECT * FROM pt_ao_1_prt_part1 WHERE twothousand = 199 ORDER BY 1;

-- pt_ao_leaf_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE fivethous = 417 ORDER BY 1;
SELECT * FROM pt_ao WHERE fivethous=417 ORDER BY 1;

-- pt_ao_exchange1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_ao WHERE stringu1 = 'ABCDEF' ORDER BY 1;
SELECT * FROM pt_ao WHERE stringu1 = 'ABCDEF' ORDER BY 1;

--------------------------------------------------------------------------------
-- AOCO PARTITIONED TABLE INDEXES
--------------------------------------------------------------------------------

-- pt_aoco_unique1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique1 < 10 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique1 < 10 ORDER BY 1;

-- pt_aoco_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique2 < 10 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique2 < 10 ORDER BY 1;

-- pt_aoco_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique1 < 10 and unique2 < 15 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique1 < 10 and unique2 < 15 ORDER BY 1;

-- pt_aoco_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE two = 1 and four = 3 ORDER BY 1;
SELECT * FROM pt_aoco WHERE two = 1 and four = 3 ORDER BY 1;

-- pt_aoco_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE stringu2 = 'WAAAAA' and string4 = 'OOOOxx' ORDER BY 1;
SELECT * FROM pt_aoco WHERE stringu2 = 'WAAAAA' and string4 = 'OOOOxx' ORDER BY 1;

-- pt_aoco_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE ten = 9 and twenty = 19 ORDER BY 1;
SELECT * FROM pt_aoco WHERE ten = 9 and twenty = 19 ORDER BY 1;

-- Validate that inserts are working after upgrade
insert into pt_aoco values (0,20,1,3,7,18,4,34,156,301,11,17,'GFABCD','PPAVxx','HJKFxx');

-- pt_aoco_unique1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique1 = 0 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique1 = 0 ORDER BY 1;

-- pt_aoco_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique2 = 20 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique2 = 20 ORDER BY 1;

-- pt_aoco_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique1 = 0 and unique2 = 20 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique1 = 0 and unique2 = 20 ORDER BY 1;

-- pt_aoco_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE two = 1 and four = 3 ORDER BY 1;
SELECT * FROM pt_aoco WHERE two = 1 and four = 3 ORDER BY 1;

-- pt_aoco_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE ten = 7 and twenty = 18 ORDER BY 1;
SELECT * FROM pt_aoco WHERE ten = 7 and twenty = 18 ORDER BY 1;

-- pt_aoco_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE string4 = 'HJKFxx' ORDER BY 1;
SELECT * FROM pt_aoco WHERE string4 = 'HJKFxx' ORDER BY 1;

-- pt_aoco_dropped_root_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE hundred = 4 ORDER BY 1;
SELECT * FROM pt_aoco WHERE hundred=4 ORDER BY 1;

-- pt_aoco_mid_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco_1_prt_part1 WHERE twothousand = 156 ORDER BY 1;
SELECT * FROM pt_aoco_1_prt_part1 WHERE twothousand = 156 ORDER BY 1;

-- pt_aoco_leaf_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE fivethous = 301 ORDER BY 1;
SELECT * FROM pt_aoco WHERE fivethous=301 ORDER BY 1;

-- pt_aoco_exchange1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE stringu1 = 'GFABCD' ORDER BY 1;
SELECT * FROM pt_aoco WHERE stringu1 = 'GFABCD' ORDER BY 1;

-- Validate that updates are working after upgrade

UPDATE pt_aoco SET unique1 = 1 WHERE unique1 = 0;
UPDATE pt_aoco SET unique2 = 19 WHERE unique2 = 20;
UPDATE pt_aoco SET two = 2, four = 4 WHERE two = 1 and four = 3;
UPDATE pt_aoco SET ten = 2, twenty = 12 WHERE ten = 7 and twenty = 18;
UPDATE pt_aoco SET string4 = 'HJKFyy' WHERE string4 = 'HJKFxx';
UPDATE pt_aoco SET hundred = 8 WHERE hundred = 4;
UPDATE pt_aoco SET twothousand = 199 WHERE twothousand = 156;
UPDATE pt_aoco SET fivethous = 417 WHERE fivethous = 301;
UPDATE pt_aoco SET stringu1 = 'ABCDEF' WHERE stringu1 = 'GFABCD';

-- pt_aoco_unique1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique1 = 1 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique1 = 1 ORDER BY 1;

-- pt_aoco_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique2 = 19 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique2 = 19 ORDER BY 1;

-- pt_aoco_unique1_unique2_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE unique1 = 1 and unique2 = 19 ORDER BY 1;
SELECT * FROM pt_aoco WHERE unique1 = 1 and unique2 = 19 ORDER BY 1;

-- pt_aoco_two_four_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE two = 2 and four = 4 ORDER BY 1;
SELECT * FROM pt_aoco WHERE two = 2 and four = 4 ORDER BY 1;

-- pt_aoco_ten_twenty_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE ten = 2 and twenty = 12 ORDER BY 1;
SELECT * FROM pt_aoco WHERE ten = 2 and twenty = 12 ORDER BY 1;

-- pt_aoco_string4_bitmap_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE string4 = 'HJKFyy' ORDER BY 1;
SELECT * FROM pt_aoco WHERE string4 = 'HJKFyy' ORDER BY 1;

-- pt_aoco_dropped_root_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE hundred = 8 ORDER BY 1;
SELECT * FROM pt_aoco WHERE hundred=8 ORDER BY 1;

-- pt_aoco_mid_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco_1_prt_part1 WHERE twothousand = 199 ORDER BY 1;
SELECT * FROM pt_aoco_1_prt_part1 WHERE twothousand = 199 ORDER BY 1;

-- pt_aoco_leaf_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE fivethous = 417 ORDER BY 1;
SELECT * FROM pt_aoco WHERE fivethous=417 ORDER BY 1;

-- pt_aoco_exchange1_idx
EXPLAIN (COSTS OFF) SELECT * FROM pt_aoco WHERE stringu1 = 'ABCDEF' ORDER BY 1;
SELECT * FROM pt_aoco WHERE stringu1 = 'ABCDEF' ORDER BY 1;

--------------------------------------------------------------------------------
-- UNIQUE CONSTRAINT
--------------------------------------------------------------------------------
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_constraint%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_constraint%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_constraint%';

EXPLAIN SELECT * FROM pt_unique_constraint WHERE a = 1;
SELECT * FROM pt_unique_constraint WHERE a = 1;

ALTER TABLE pt_unique_constraint DROP CONSTRAINT pt_unique_constraint_a_key;

-- expect 0 rows
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_constraint%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_constraint%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_constraint%';

--------------------------------------------------------------------------------
-- UNIQUE CONSTRAINT WITH EXCHANGE
--------------------------------------------------------------------------------
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_exchange%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_exchange%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_exchange%';

EXPLAIN SELECT * FROM pt_unique_exchange WHERE a = 1;
SELECT * FROM pt_unique_exchange WHERE a = 1;

ALTER TABLE pt_unique_exchange DROP CONSTRAINT pt_unique_exchange_a_key;

-- expect 0 rows
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_exchange%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_exchange%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_exchange%';

--------------------------------------------------------------------------------
-- UNIQUE CONSTRAINT INSIDE CREATE TABLE DDL
--------------------------------------------------------------------------------
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_inside_create_table%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_inside_create_table%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_inside_create_table%';

EXPLAIN SELECT * FROM pt_unique_inside_create_table WHERE a = 1;
SELECT * FROM pt_unique_inside_create_table WHERE a = 1;

ALTER TABLE pt_unique_inside_create_table DROP CONSTRAINT pt_unique_inside_create_table_key;

-- expect 0 rows
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_inside_create_table%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_inside_create_table%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_inside_create_table%';

--------------------------------------------------------------------------------
-- UNIQUE INDEX WITH UNIQUE CONSTRAINT HAVING SAME NAME
--------------------------------------------------------------------------------
SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_index_same_name%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_index_same_name%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_index_same_name%';

EXPLAIN SELECT * FROM pt_unique_index_same_name WHERE a = 1;
SELECT * FROM pt_unique_index_same_name WHERE a = 1;

ALTER TABLE pt_unique_index_same_name DROP CONSTRAINT pt_unique_index_same_name_a_key1;

SELECT * FROM index_backed_constraints() WHERE table_name LIKE 'pt_unique_index_same_name%';
SELECT * FROM root_partition_indexes() WHERE table_name LIKE 'pt_unique_index_same_name%';
SELECT * FROM child_partition_indexes() WHERE table_name LIKE 'pt_unique_index_same_name%';
