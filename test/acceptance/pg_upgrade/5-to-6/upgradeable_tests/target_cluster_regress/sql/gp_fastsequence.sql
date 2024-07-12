-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

--------------------------------------------------------------------------------
-- Validate gp_fastsequence was upgraded
--------------------------------------------------------------------------------

-- Verify table's gp_fastsequence value is preserved
SELECT fs.gp_segment_id, fs.objmod, fs.last_sequence
FROM pg_class c
JOIN pg_appendonly ao ON c.oid=ao.relid
JOIN gp_dist_random('gp_fastsequence') fs ON ao.segrelid=fs.objid
WHERE c.relname='aotable_fastsequence'
ORDER BY 1, 2, 3;

-- Verify table data is not corrupt using seqscan
SET enable_indexscan = false;
SET enable_bitmapscan = false;
SET enable_seqscan = true;
SET optimizer = off;

EXPLAIN (COSTS OFF) SELECT * FROM aotable_fastsequence ORDER BY i;
SELECT * FROM aotable_fastsequence ORDER BY i;

-- Verify INSERTs produce no duplicate ctids
1: BEGIN;
1: INSERT INTO aotable_fastsequence SELECT generate_series(1001, 1010);
2: INSERT INTO aotable_fastsequence SELECT generate_series(1011, 1020);
1: COMMIT;
SELECT gp_segment_id, ctid, count(ctid) FROM aotable_fastsequence GROUP BY gp_segment_id, ctid HAVING count(ctid) > 1;

SET enable_indexscan = true;
SET enable_bitmapscan = true;
SET enable_seqscan = false;

EXPLAIN (COSTS OFF) SELECT * FROM aotable_fastsequence ORDER BY i;
SELECT * FROM aotable_fastsequence WHERE i < 10 ORDER BY i;

-- Verify table's gp_fastsequence value is preserved
SELECT fs.gp_segment_id, fs.objmod, fs.last_sequence
FROM pg_class c
JOIN pg_appendonly ao ON c.oid=ao.relid
JOIN gp_dist_random('gp_fastsequence') fs ON ao.segrelid=fs.objid
WHERE c.relname='aocotable_fastsequence'
ORDER BY 1, 2, 3;

-- Verify table data is not corrupt using seqscan
SET enable_indexscan = false;
SET enable_bitmapscan = false;
SET enable_seqscan = true;

EXPLAIN (COSTS OFF) SELECT * FROM aocotable_fastsequence ORDER BY i;
SELECT * FROM aocotable_fastsequence ORDER BY i;

-- Verify INSERTs produce no duplicate ctids
1: BEGIN;
1: INSERT INTO aocotable_fastsequence SELECT generate_series(1001, 1010);
2: INSERT INTO aocotable_fastsequence SELECT generate_series(1011, 1020);
1: COMMIT;
SELECT gp_segment_id, ctid, count(ctid) FROM aocotable_fastsequence GROUP BY gp_segment_id, ctid HAVING count(ctid) > 1;

SET enable_indexscan = true;
SET enable_bitmapscan = true;
SET enable_seqscan = false;

EXPLAIN (COSTS OFF) SELECT * FROM aocotable_fastsequence ORDER BY i;
SELECT * FROM aocotable_fastsequence WHERE i < 10 ORDER BY i;
