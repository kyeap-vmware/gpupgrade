-- Copyright (c) 2017-2024 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- Test to encodings are preserved after upgrade

--------------------------------------------------------------------------------
-- Create and setup upgradeable objects
--------------------------------------------------------------------------------
SELECT datname, encoding, datcollate, datctype
FROM pg_catalog.pg_database
WHERE datname = 'template0';
