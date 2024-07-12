-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- Test to ensure that tables with tsvector columns can be upgraded.
-- pg_upgrade reference: old_8_3_rebuild_tsvector_tables
-- 8.3 sorts lexemes by its length and if lengths are the same then it uses
-- alphabetic order;  8.4 sorts lexemes in lexicographical order, e.g.
-- => SELECT 'c bb aaa'::tsvector;
--   tsvector
--   ----------------
--    'aaa' 'bb' 'c'		   -- 8.4
--    'c' 'bb' 'aaa'		   -- 8.3

-- Verify that the table is still usable after upgrade and the tsvector column is sorted correctly
-- in lexicographical order.
EXPLAIN (COSTS OFF) SELECT * FROM tsvector_table;
SELECT * FROM tsvector_table;
