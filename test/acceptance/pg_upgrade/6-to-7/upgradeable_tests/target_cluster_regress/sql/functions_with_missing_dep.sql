-- Copyright (c) 2017-2024 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

-- Test to ensure functions with missing dependencies can be upgraded. Not all
-- function dependencies are recorded in pg_depend. This makes it very
-- difficult to check if functions will start to fail post upgrade due to
-- missing dependecies. Examples of this are functions using types, tables, or
-- views that are removed in the next major version. Fortunately such functions
-- are still restorable by disabling GUC check_function_bodies. It will be up
-- to the user to fix their fuctions post upgrade if they start failing with
-- error `ERROR:  relation "xxx" does not exist`.

-- check function was restored
SELECT proname, prosrc FROM pg_proc where proname = 'func_with_missing_dep';

-- function does not run because it is missing dependency
SELECT * FROM func_with_missing_dep();
