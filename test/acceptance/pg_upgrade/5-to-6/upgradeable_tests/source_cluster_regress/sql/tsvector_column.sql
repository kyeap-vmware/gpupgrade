-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- Test to ensure that tables with tsvector columns can be upgraded.

--------------------------------------------------------------------------------
-- Create and setup upgradeable objects
--------------------------------------------------------------------------------
CREATE TABLE tsvector_table(a int, b tsvector);
INSERT INTO tsvector_table SELECT i, to_tsvector('english', 'aaa' || i || ' ' || 'bb' || i || ' ' || 'c' || i) FROM generate_series(1,10)i;
CREATE INDEX tsvector_table_idx ON tsvector_table USING gist(b);
SELECT * FROM tsvector_table;
