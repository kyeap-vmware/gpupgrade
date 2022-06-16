-- Copyright (c) 2017-2022 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- Ensure data migration scripts fully qualify objects by creating the
-- non-upgradable objects in a custom schema.
DROP SCHEMA IF EXISTS testschema CASCADE;
CREATE SCHEMA testschema;
SET search_path to testschema;

DROP TABLE IF EXISTS regular CASCADE;
CREATE TABLE regular (a int unique);

-- create partitioned table with foreign key constraints
DROP TABLE IF EXISTS pt_with_index CASCADE;
CREATE TABLE pt_with_index (a int references regular(a), b int, c int, d int)
    PARTITION BY RANGE(b)
        (
        PARTITION pt1 START(1),
        PARTITION pt2 START(2) END (3),
        PARTITION pt3 START(3) END (4)
        );

CREATE INDEX ptidxc on pt_with_index(c);
CREATE INDEX ptidxc_bitmap on pt_with_index using bitmap(c);

CREATE INDEX ptidxb_prt_2 on pt_with_index_1_prt_pt2(b);
CREATE INDEX ptidxb_prt_2_bitmap on pt_with_index_1_prt_pt2 using bitmap(b);

CREATE INDEX ptidxc_prt_2 on pt_with_index_1_prt_pt2(c);
CREATE INDEX ptidxc_prt_2_bitmap on pt_with_index_1_prt_pt2 using bitmap(c);
INSERT INTO pt_with_index SELECT i, i%2+1, i, i FROM generate_series(1,10)i;

-- create multi level partitioned table with indexes
DROP TABLE IF EXISTS sales;
CREATE TABLE sales (trans_id int, office_id int, region text)
    DISTRIBUTED BY (trans_id)
    PARTITION BY RANGE (office_id)
        SUBPARTITION BY LIST (region)
            SUBPARTITION TEMPLATE
            ( SUBPARTITION usa VALUES ('usa'),
            SUBPARTITION asia VALUES ('asia'),
            SUBPARTITION europe VALUES ('europe'),
            DEFAULT SUBPARTITION other_regions)
        (START (1) END (4) EVERY (1),
        DEFAULT PARTITION outlying_dates );

CREATE INDEX sales_idx on sales(office_id);
CREATE INDEX sales_idx_bitmap on sales using bitmap(office_id);
CREATE INDEX sales_1_prt_2_idx on sales_1_prt_2(office_id, region);
CREATE INDEX sales_1_prt_3_2_prt_asia_idx on sales_1_prt_3_2_prt_asia(region);
CREATE INDEX sales_1_prt_outlying_dates_idx on sales_1_prt_outlying_dates(trans_id);
CREATE UNIQUE INDEX sales_unique_idx on sales(office_id);

-- create tables where the index relation name is not equal primary/unique key constraint name.
-- we create a TYPE with the default name of the constraint that would have been created to force
-- skipping the default name
DROP TABLE IF EXISTS table_with_unique_constraint;
CREATE TYPE table_with_unique_constraint_author_key AS (dummy int);
CREATE TYPE table_with_unique_constraint_author_key1 AS (dummy int);
CREATE TABLE table_with_unique_constraint (author int, title int, CONSTRAINT table_with_unique_constraint_uniq_au_ti UNIQUE (author, title)) DISTRIBUTED BY (author);
DROP TYPE table_with_unique_constraint_author_key, table_with_unique_constraint_author_key1;
ALTER TABLE table_with_unique_constraint ADD PRIMARY KEY (author, title);
INSERT INTO table_with_unique_constraint VALUES(1, 1);
INSERT INTO table_with_unique_constraint VALUES(2, 2);

DROP TABLE IF EXISTS table_with_primary_constraint;
CREATE TYPE table_with_primary_constraint_pkey AS (dummy int);
CREATE TYPE table_with_primary_constraint_pkey1 AS (dummy int);
CREATE TABLE table_with_primary_constraint (author int, title int, CONSTRAINT table_with_primary_constraint_au_ti PRIMARY KEY (author, title)) DISTRIBUTED BY (author);
DROP TYPE table_with_primary_constraint_pkey, table_with_primary_constraint_pkey1;
ALTER TABLE table_with_primary_constraint ADD UNIQUE (author, title);
INSERT INTO table_with_primary_constraint VALUES(1, 1);
INSERT INTO table_with_primary_constraint VALUES(2, 2);

-- create partitioned tables where the index relation name is not equal primary/unique key constraint name for the root
-- Note that the naming of the constraint is key, not the type of constraint
-- If the constraint is named, every partition will have the same named constraint and they all can be dropped with the same command
-- If the constraint is not named, greenplum generates a unique name for each partition as well as the coordinator table. We can only drop the coordinator tables constraint and the partition constraints remain in effect
DROP TABLE IF EXISTS table_with_unique_constraint_p;
CREATE TYPE unique_constraint_p_author_key AS (dummy int);
CREATE TYPE unique_constraint_p_author_key1 AS (dummy int);
CREATE TABLE table_with_unique_constraint_p (author int, title int, CONSTRAINT unique_constraint_p_uniq_au_ti UNIQUE (author, title)) PARTITION BY RANGE(title) (START(1) END(4) EVERY(1));
DROP TYPE unique_constraint_p_author_key, unique_constraint_p_author_key1;
ALTER TABLE table_with_unique_constraint_p ADD PRIMARY KEY (author, title);
INSERT INTO table_with_unique_constraint_p VALUES(1, 1);
INSERT INTO table_with_unique_constraint_p VALUES(2, 2);

DROP TABLE IF EXISTS table_with_primary_constraint_p;
CREATE TYPE primary_constraint_p_pkey AS (dummy int);
CREATE TYPE primary_constraint_p_pkey1 AS (dummy int);
CREATE TABLE table_with_primary_constraint_p (author int, title int, CONSTRAINT primary_constraint_p_au_ti PRIMARY KEY (author, title)) PARTITION BY RANGE(title) (START(1) END(4) EVERY(1));
DROP TYPE primary_constraint_p_pkey, primary_constraint_p_pkey1;
ALTER TABLE table_with_primary_constraint_p ADD UNIQUE (author, title);
INSERT INTO table_with_primary_constraint_p VALUES(1, 1);
INSERT INTO table_with_primary_constraint_p VALUES(2, 2);

-- create external gphdfs table
-- NOTE: We fake the gphdfs protocol here so that it doesn't actually have to be
-- installed.
CREATE OR REPLACE FUNCTION noop() RETURNS integer AS 'select 0' LANGUAGE SQL;
DROP PROTOCOL IF EXISTS gphdfs CASCADE;
CREATE PROTOCOL gphdfs (writefunc=noop, readfunc=noop);

CREATE EXTERNAL TABLE ext_gphdfs (name text)
	LOCATION ('gphdfs://example.com/data/filename.txt')
	FORMAT 'TEXT' (DELIMITER '|');
CREATE EXTERNAL TABLE "ext gphdfs" (name text) -- whitespace in the name
	LOCATION ('gphdfs://example.com/data/filename.txt')
	FORMAT 'TEXT' (DELIMITER '|');

-- create name datatype attributes as the not-first column
DROP TABLE IF EXISTS table_with_name_as_second_column;
CREATE TABLE table_with_name_as_second_column (a int, "first last" name);
INSERT INTO table_with_name_as_second_column VALUES(1, 'George Washington');
INSERT INTO table_with_name_as_second_column VALUES(1, 'Henry Ford');
-- create partition table with name datatype attribute as the not-first column as the partition key
DROP TABLE IF EXISTS partition_table_partitioned_by_name_type;
CREATE TABLE partition_table_partitioned_by_name_type(a int, b name) PARTITION BY RANGE (b) (START('a') END('z'));
-- create table with name datatype attribute as the not-first column as the distribution key
DROP TABLE IF EXISTS table_distributed_by_name_type;
CREATE TABLE table_distributed_by_name_type(a int, b name) DISTRIBUTED BY (b);
INSERT INTO table_distributed_by_name_type VALUES (1,'z'),(2,'x');
-- create table / views with name datatype
CREATE TABLE t1_with_name(a name, b name) DISTRIBUTED RANDOMLY;
INSERT INTO t1_with_name SELECT 'aaa', 'bbb';
CREATE TABLE t2_with_name(a int, b name) DISTRIBUTED RANDOMLY;
INSERT INTO t2_with_name SELECT 1, 'bbb';
CREATE VIEW v2_on_t2_with_name AS SELECT * FROM t2_with_name;
-- multilevel partition table with partitioning keys using name datatype
CREATE TABLE multilevel_part_with_partition_col_name_datatype (trans_id int, country name, amount decimal(9,2), region name)
DISTRIBUTED BY (trans_id)
PARTITION BY LIST (country)
SUBPARTITION BY LIST (region)
SUBPARTITION TEMPLATE
( SUBPARTITION south VALUES ('south'),
    DEFAULT SUBPARTITION other_regions)
    (PARTITION usa VALUES ('usa'),
    DEFAULT PARTITION outlying_country );
-- multilevel partition table with partitioning keys using not using name datatype
CREATE TABLE multilevel_part_with_partition_col_text_datatype (trans_id int, country text, state name, region text)
DISTRIBUTED BY (trans_id)
PARTITION BY LIST (country)
SUBPARTITION BY LIST (region)
SUBPARTITION TEMPLATE
( SUBPARTITION south VALUES ('south'),
    DEFAULT SUBPARTITION other_regions)
    (PARTITION usa VALUES ('usa'),
    DEFAULT PARTITION outlying_country );

-- create tables with tsquery datatype
DROP TABLE IF EXISTS table_with_tsquery_datatype_columns;
CREATE TABLE table_with_tsquery_datatype_columns(a tsquery, b tsquery, c tsquery, d int)
    PARTITION BY RANGE(d) (START(1) END(4) EVERY(1));
INSERT INTO table_with_tsquery_datatype_columns
    VALUES  ('b & c'::tsquery, 'b & c'::tsquery, 'b & c'::tsquery, 1),
            ('e & f'::tsquery, 'e & f'::tsquery, 'e & f'::tsquery, 2),
            ('x & y'::tsquery, 'x & y'::tsquery, 'x & y'::tsquery, 3);

-- Index tests on tsquery
--composite index
DROP TABLE IF EXISTS tsquery_composite;
CREATE TABLE tsquery_composite(i int, j tsquery, k tsquery);
CREATE INDEX tsquery_composite_idx ON tsquery_composite(j, k);
--gist index
DROP TABLE IF EXISTS tsquery_gist;
CREATE TABLE tsquery_gist(i int, j tsquery, k tsquery);
CREATE INDEX tsquery_gist_idx ON tsquery_gist using gist(j) ;
--clustered index with comment
DROP TABLE IF EXISTS tsquery_cluster_comment;
CREATE TABLE tsquery_cluster_comment(i int, j tsquery);
CREATE INDEX tsquery_cluster_comment_idx ON tsquery_cluster_comment(j);
ALTER TABLE tsquery_cluster_comment CLUSTER ON tsquery_cluster_comment_idx;
COMMENT ON INDEX tsquery_cluster_comment_idx IS 'hello world';

-- Index tests on name
--composite index
DROP TABLE IF EXISTS name_composite;
CREATE TABLE name_composite(i int, j name, k name);
CREATE INDEX name_composite_idx ON name_composite(j, k);
--clustered index with comment
DROP TABLE IF EXISTS name_cluster_comment;
CREATE TABLE name_cluster_comment(i int, j name);
CREATE INDEX name_cluster_comment_idx ON name_cluster_comment(j);
ALTER TABLE name_cluster_comment CLUSTER ON name_cluster_comment_idx;
COMMENT ON INDEX name_cluster_comment_idx IS 'hello world';

-- inherits with tsquery column
DROP TABLE IF EXISTS tsquery_inherits;
CREATE TABLE tsquery_inherits (
    e      tsquery
) INHERITS (table_with_tsquery_datatype_columns);

-- inherits with name and tsquery columns
DROP TABLE IF EXISTS table_with_name_column;
CREATE TABLE table_with_name_tsquery (
    name       text,
    population name,
    altitude   tsquery
);
CREATE INDEX table_with_name_tsquery_name_idx on table_with_name_tsquery(population);
CREATE INDEX table_with_name_tsquery_tsquery_idx on table_with_name_tsquery(altitude);

DROP TABLE IF EXISTS name_inherits;
CREATE TABLE name_inherits (
    state      char(2)
) INHERITS (table_with_name_tsquery);

-- view on a view on a name column with owner different than the underlying table
DROP VIEW IF EXISTS v3_on_v2_recursive;
CREATE VIEW v3_on_v2_recursive AS SELECT * FROM v2_on_t2_with_name;
ALTER TABLE v3_on_v2_recursive OWNER TO test_role;

-- Third level recursive view on a name column
DROP VIEW IF EXISTS v4_on_v3_recursive;
CREATE VIEW v4_on_v3_recursive AS SELECT * FROM v3_on_v2_recursive;

-- view on a table with view that doesn't actually depend on the name column
-- this one should not be dropped since its dependent columns are not changing
DROP VIEW IF EXISTS v4_on_t2_no_name;
CREATE VIEW v4_on_t2_no_name AS SELECT a, 1::INTEGER AS i FROM t2_with_name;

-- view on both name and tsquery from the same table
DROP VIEW IF EXISTS view_on_name_tsquery;
CREATE VIEW view_on_name_tsquery AS SELECT * FROM table_with_name_tsquery;

-- view on both name and tsquery from multiple tables
DROP VIEW IF EXISTS view_on_name_tsquery_mult_tables;
CREATE VIEW view_on_name_tsquery_mult_tables AS SELECT t1.population, t2.altitude FROM table_with_name_tsquery t1, table_with_name_tsquery t2;

CREATE TABLE sales_name (trans_id int, office_name name, region text)
    DISTRIBUTED BY (trans_id)
    PARTITION BY LIST (office_name)
            ( PARTITION usa VALUES ('usa'),
            PARTITION asia VALUES ('asia'),
            PARTITION europe VALUES ('europe'),
            DEFAULT PARTITION other_regions);

CREATE INDEX sales_name_idx on sales_name(office_name);

CREATE TABLE sales_tsquery (trans_id int, office_tsquery tsquery, region text)
    DISTRIBUTED BY (trans_id)
    PARTITION BY LIST (office_tsquery)
            ( PARTITION usa VALUES ('usa'),
            PARTITION asia VALUES ('asia'),
            PARTITION europe VALUES ('europe'),
            DEFAULT PARTITION other_regions);

CREATE INDEX sales_tsquery_idx on sales_tsquery USING GIST (office_tsquery);

-- Multilevel partitioned table with unique index
DROP TABLE IF EXISTS ml_partitioned_with_index;
CREATE TABLE ml_partitioned_with_index (trans_id int, office_id int, region int, dummy int)
DISTRIBUTED BY (trans_id)
    PARTITION BY RANGE (office_id)
        SUBPARTITION BY RANGE (dummy)
            SUBPARTITION TEMPLATE (
            START (1) END (16) EVERY (4),
            DEFAULT SUBPARTITION other_dummy )
        (START (1) END (4) EVERY (1),
        DEFAULT PARTITION outlying_dates );
CREATE UNIQUE INDEX ml_partitioned_with_index_idx ON ml_partitioned_with_index(trans_id);

-- heterogeneous partitioned tables
-- copied from acceptance tests

-- Heterogeneous partition table with dropped column
-- The root and only a subset of children have the dropped column reference.
CREATE TABLE dropped_column (a int CONSTRAINT positive_int CHECK (b > 0), b int DEFAULT 1, c char, d varchar(50)) DISTRIBUTED BY (c)
    PARTITION BY RANGE (a)
        (PARTITION part_1 START(1) END(5),
        PARTITION part_2 START(5));
ALTER TABLE dropped_column DROP COLUMN d;
ALTER TABLE dropped_column OWNER TO testrole;

-- Splitting the subpartition leads to its rewrite, eliminating its dropped column
-- reference. So, after this, only part_2 and the root partition will have a
-- dropped column reference.
ALTER TABLE dropped_column SPLIT PARTITION FOR(1) AT (2) INTO (PARTITION split_part_1, PARTITION split_part_2);
INSERT INTO dropped_column VALUES(1, 2, 'a');

-- Root partitions do not have dropped column references, but some child partitions do
CREATE TABLE child_has_dropped_column (a int, b int, c char, d varchar(50))
    PARTITION BY RANGE (a)
        (PARTITION part_1 START(1) END(5),
        PARTITION part_2 START(5));

CREATE TABLE intermediate_table (a int, b int, c char, d varchar(50), to_drop int);
ALTER TABLE intermediate_table DROP COLUMN to_drop;

ALTER TABLE child_has_dropped_column EXCHANGE PARTITION part_1 WITH TABLE intermediate_table;
DROP TABLE intermediate_table;

-- heterogeneous multilevel partitioned table
DROP TABLE IF EXISTS heterogeneous_ml_partition_table;
CREATE TABLE heterogeneous_ml_partition_table (trans_id int, office_id int, region int, dummy int)
    DISTRIBUTED BY (trans_id)
    PARTITION BY RANGE (office_id)
        SUBPARTITION BY RANGE (dummy)
            SUBPARTITION TEMPLATE (
            START (1) END (16) EVERY (4),
            DEFAULT SUBPARTITION other_dummy )
        (START (1) END (4) EVERY (1),
        DEFAULT PARTITION outlying_dates );

ALTER TABLE heterogeneous_ml_partition_table DROP COLUMN region;
ALTER TABLE heterogeneous_ml_partition_table ALTER PARTITION for (1) SPLIT PARTITION for (1) at (3) into (PARTITION p1, PARTITION p2);

RESET search_path;
