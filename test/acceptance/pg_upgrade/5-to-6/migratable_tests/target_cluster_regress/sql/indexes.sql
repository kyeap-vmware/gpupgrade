-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0.

-- The indexes in this test can be migrated, but are marked as
-- invalid on the target cluster during execute. They must be
-- REINDEX'd on the target cluster during finalize to rebuild
-- and reset them to valid.

-------------------------------------------------------------------------------
-- Validate that the indexes still work after finalize or revert
-------------------------------------------------------------------------------

-- Show what the indexes are
SELECT c.relname, a.amname, i.indisvalid FROM pg_class c JOIN pg_am a ON c.relam = a.oid JOIN pg_index i ON i.indexrelid = c.oid WHERE c.relname SIMILAR TO '(ao|aoco|heap)_with_(btree|bitmap|gist|bpchar_pattern_ops)_idx';

-- Verify there are no invalid indexes
SELECT c.relname, i.indisvalid FROM pg_class c JOIN pg_index i ON i.indexrelid = c.oid WHERE i.indisvalid = false;

SET enable_indexscan = true;
SET enable_bitmapscan = true;
SET enable_seqscan = false;
SET optimizer = off;

-- Verify that the indexes are still usable after upgrade
EXPLAIN SELECT * FROM heap_with_bpchar_pattern_ops WHERE b::bpchar LIKE '1';
EXPLAIN SELECT * FROM heap_with_bitmap WHERE b = 1;
EXPLAIN SELECT * FROM ao_with_btree WHERE b > 8;
EXPLAIN SELECT * FROM ao_with_bitmap WHERE b = 1;
EXPLAIN SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext1');
EXPLAIN SELECT * FROM aoco_with_btree WHERE b > 8;
EXPLAIN SELECT * FROM aoco_with_bitmap WHERE b = 1;
EXPLAIN SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext1');
SELECT * FROM heap_with_bpchar_pattern_ops WHERE b::bpchar LIKE '1';
SELECT * FROM heap_with_bitmap WHERE b = 1;
SELECT * FROM ao_with_btree WHERE b > 8;
SELECT * FROM ao_with_bitmap WHERE b = 1;
SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext1');
SELECT * FROM aoco_with_btree WHERE b > 8;
SELECT * FROM aoco_with_bitmap WHERE b = 1;
SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext1');

-- Verify that new inserts can be found via the index
INSERT INTO heap_with_bpchar_pattern_ops SELECT i,i::bpchar FROM generate_series(11,20)i;
INSERT INTO heap_with_bitmap SELECT i,i FROM generate_series(11,20)i;
INSERT INTO ao_with_btree SELECT i,i FROM generate_series(11,20)i;
INSERT INTO ao_with_bitmap SELECT i,i%3 FROM generate_series(1,10)i;
INSERT INTO ao_with_gist SELECT 1,j.res::tsvector FROM (SELECT 'footext' || i%4 AS res FROM generate_series(1,10) i) j;
INSERT INTO aoco_with_btree SELECT i,i FROM generate_series(11,20)i;
INSERT INTO aoco_with_bitmap SELECT i,i%3 FROM generate_series(1,10)i;
INSERT INTO aoco_with_gist SELECT 1,j.res::tsvector FROM (SELECT 'footext' || i%4 AS res FROM generate_series(1,10) i) j;

EXPLAIN SELECT * FROM heap_with_bpchar_pattern_ops WHERE b::bpchar LIKE '11';
EXPLAIN SELECT * FROM heap_with_bitmap WHERE b = 1;
EXPLAIN SELECT * FROM ao_with_btree WHERE b > 11;
EXPLAIN SELECT * FROM ao_with_bitmap WHERE b = 1;
EXPLAIN SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext3');
EXPLAIN SELECT * FROM aoco_with_btree WHERE b > 11;
EXPLAIN SELECT * FROM aoco_with_bitmap WHERE b = 1;
EXPLAIN SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext3');
SELECT * FROM heap_with_bpchar_pattern_ops WHERE b::bpchar LIKE '11';
SELECT * FROM heap_with_bitmap WHERE b = 1;
SELECT * FROM ao_with_btree WHERE b > 11;
SELECT * FROM ao_with_bitmap WHERE b = 1;
SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext3');
SELECT * FROM aoco_with_btree WHERE b > 11;
SELECT * FROM aoco_with_bitmap WHERE b = 1;
SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext3');

-- Verify that updates can be found via the index
UPDATE heap_with_bpchar_pattern_ops SET b = '21' WHERE b = '11';
UPDATE heap_with_bitmap SET b = 4 WHERE b = 1;
UPDATE ao_with_btree SET b = 21 WHERE b = 11;
UPDATE ao_with_bitmap SET b = 4 WHERE b = 1;
UPDATE ao_with_gist SET b = 'footext5' WHERE b = 'footext3';
UPDATE aoco_with_btree SET b = 21 WHERE b = 11;
UPDATE aoco_with_bitmap SET b = 4 WHERE b = 1;
UPDATE aoco_with_gist SET b = 'footext5' WHERE b = 'footext3';

EXPLAIN SELECT * FROM heap_with_bpchar_pattern_ops WHERE b::bpchar LIKE '11';
EXPLAIN SELECT * FROM heap_with_bitmap WHERE b = 4;
EXPLAIN SELECT * FROM ao_with_btree WHERE b > 11;
EXPLAIN SELECT * FROM ao_with_bitmap WHERE b = 4;
EXPLAIN SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext5');
EXPLAIN SELECT * FROM aoco_with_btree WHERE b > 11;
EXPLAIN SELECT * FROM aoco_with_bitmap WHERE b = 4;
EXPLAIN SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext5');
SELECT * FROM heap_with_bpchar_pattern_ops WHERE a::bpchar LIKE '11';
SELECT * FROM heap_with_bitmap WHERE b = 4;
SELECT * FROM ao_with_btree WHERE b > 11;
SELECT * FROM ao_with_bitmap WHERE b = 4;
SELECT * FROM ao_with_gist WHERE b @@ to_tsquery('footext5');
SELECT * FROM aoco_with_btree WHERE b > 11;
SELECT * FROM aoco_with_bitmap WHERE b = 4;
SELECT * FROM aoco_with_gist WHERE b @@ to_tsquery('footext5');

-- Check unused aoblkdir edge case is filtered out and not upgraded
SELECT c.relname AS relname,
CASE
	WHEN a.blkdirrelid = 0 THEN 'False'
	ELSE 'True'
END AS has_aoblkdir
FROM pg_appendonly a
JOIN pg_class c on c.oid=a.relid
WHERE c.relname='aotable_with_all_indexes_dropped';
