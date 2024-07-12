-- Copyright (c) 2017-2023 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

--------------------------------------------------------------------------------
-- Validate that the upgradeable objects are functional post-upgrade
--------------------------------------------------------------------------------

-- VACUUM FREEZE the entire database to ensure there are no failures.
VACUUM FREEZE;

-- should be able to create a new table without any warnings related to vacuum
CREATE TABLE upgraded_vf_tbl_heap (LIKE vf_tbl_heap);
INSERT INTO upgraded_vf_tbl_heap SELECT * FROM vf_tbl_heap;
VACUUM FREEZE upgraded_vf_tbl_heap;
SELECT * FROM upgraded_vf_tbl_heap;
