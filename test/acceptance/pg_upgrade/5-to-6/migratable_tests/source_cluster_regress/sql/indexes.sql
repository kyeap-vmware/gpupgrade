-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- The indexes in this test can be migrated, but are marked as
-- invalid on the target cluster during execute. They must be
-- REINDEX'd on the target cluster during finalize to rebuild
-- and reset them to valid.

--------------------------------------------------------------------------------
-- Create and setup migratable objects
--------------------------------------------------------------------------------

CREATE TABLE heap_with_bpchar_pattern_ops(a int, b bpchar);
CREATE TABLE heap_with_bitmap(a int, b int);
CREATE TABLE ao_with_btree(a int, b int) WITH (appendonly=true);
CREATE TABLE ao_with_bitmap(a int, b int) WITH (appendonly=true);
CREATE TABLE ao_with_gist(a int, b tsvector) WITH (appendonly=true);
CREATE TABLE aoco_with_btree(a int, b int) WITH (appendonly=true, orientation=column);
CREATE TABLE aoco_with_bitmap(a int, b int) WITH (appendonly=true, orientation=column);
CREATE TABLE aoco_with_gist(a int, b tsvector) WITH (appendonly=true, orientation=column);

INSERT INTO heap_with_bpchar_pattern_ops SELECT i,i::bpchar FROM generate_series(1,10)i;
INSERT INTO heap_with_bitmap SELECT i,i FROM generate_series(1,10)i;
INSERT INTO ao_with_btree SELECT i,i FROM generate_series(1,10)i;
INSERT INTO ao_with_bitmap SELECT i,i%5 FROM generate_series(1,10)i;
INSERT INTO ao_with_gist SELECT 1,j.res::tsvector FROM (SELECT 'footext' || i%3 AS res FROM generate_series(1,10) i) j;
INSERT INTO aoco_with_btree SELECT i,i FROM generate_series(1,10)i;
INSERT INTO aoco_with_bitmap SELECT i,i%5 FROM generate_series(1,10)i;
INSERT INTO aoco_with_gist SELECT 1,j.res::tsvector FROM (SELECT 'footext' || i%3 AS res FROM generate_series(1,10) i) j;

CREATE INDEX heap_with_bpchar_pattern_ops_idx on heap_with_bpchar_pattern_ops (b bpchar_pattern_ops);
CREATE INDEX heap_with_bitmap_idx on heap_with_bitmap using bitmap(b);
CREATE INDEX ao_with_btree_idx ON ao_with_btree USING btree(b);
CREATE INDEX ao_with_bitmap_idx ON ao_with_bitmap USING bitmap(b);
CREATE INDEX ao_with_gist_idx ON ao_with_gist USING gist(b);
CREATE INDEX aoco_with_btree_idx ON aoco_with_btree USING btree(b);
CREATE INDEX aoco_with_bitmap_idx ON aoco_with_bitmap USING bitmap(b);
CREATE INDEX aoco_with_gist_idx ON aoco_with_gist USING gist(b);

-- Show what the indexes are before upgrade
SELECT c.relname, a.amname FROM pg_class c JOIN pg_am a ON c.relam = a.oid WHERE relname SIMILAR TO '(ao|aoco|heap)_with_(btree|bitmap|gist|bpchar_pattern_ops)_idx';

-- Show that the indexes are usable before upgrade
SET enable_indexscan = true;
SET enable_bitmapscan = true;
SET enable_seqscan = false;
SET optimizer = off;

SELECT * FROM heap_with_bpchar_pattern_ops WHERE b::bpchar LIKE '1';
SELECT * FROM heap_with_bitmap WHERE b = 1;
SELECT * FROM ao_with_btree WHERE b > 8;
SELECT * FROM ao_with_bitmap WHERE b = 1;
SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext1');
SELECT * FROM aoco_with_btree WHERE b > 8;
SELECT * FROM aoco_with_bitmap WHERE b = 1;
SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext1');



-- When the last index on an AO table is deleted, the table's corresponding
-- pg_aoblkdir is not deleted. The aoblkdir is first created when an index is
-- created for the AO table. If an index is created for an AO table then
-- deleted, an aodblkdir relation is left on the source cluster. During
-- pg_upgrade, pg_dump will not dump an index which means the aoblkdir does not
-- get created on the target cluster. If this is not accounted for, pg_upgrade
-- will error out due to relation mismatch. To resolve this edge case,
-- pg_upgrade filters out aoblkdirs for AO tables with no indexes.

-- Setup AO table with unused aoblkdir
CREATE TABLE aotable_with_all_indexes_dropped(i int) WITH (appendonly=true);
CREATE INDEX idx on aotable_with_all_indexes_dropped(i);
DROP INDEX idx;

-- Check unused aoblkdir exists
SELECT c.relname AS relname,
CASE
	WHEN a.blkdirrelid = 0 THEN 'False'
	ELSE 'True'
END AS has_aoblkdir
FROM pg_appendonly a
JOIN pg_class c on c.oid=a.relid
WHERE c.relname='aotable_with_all_indexes_dropped';
