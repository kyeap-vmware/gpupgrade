-- Copyright (c) 2017-2024 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- Test to encodings are preserved after upgrade

--------------------------------------------------------------------------------
-- Create and setup upgradeable objects
--------------------------------------------------------------------------------
SET allow_system_table_mods=true;

UPDATE pg_catalog.pg_database
SET encoding = 0,
    datcollate = 'C',
    datctype = 'C'
WHERE datname = 'template0';

SELECT datname, encoding, datcollate, datctype
FROM pg_catalog.pg_database
WHERE datname = 'template0';
