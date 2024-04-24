-- Copyright (c) 2017-2024 VMware, Inc. or its affiliates
-- SPDX-License-Identifier: Apache-2.0

--------------------------------------------------------------------------------
-- Create and setup non-upgradeable objects
--------------------------------------------------------------------------------

CREATE DATABASE all_upgradable_gucs_db;
ALTER DATABASE all_upgradable_gucs_db SET allow_system_table_mods = true;
ALTER DATABASE all_upgradable_gucs_db SET trace_notify = true;

CREATE DATABASE some_nonupgradable_gucs_db;
ALTER DATABASE some_nonupgradable_gucs_db SET allow_system_table_mods = true;
ALTER DATABASE some_nonupgradable_gucs_db SET autocommit = true;

CREATE DATABASE all_nonupgradable_gucs_db;
ALTER DATABASE all_nonupgradable_gucs_db SET autocommit = true;
ALTER DATABASE all_nonupgradable_gucs_db SET debug_latch = true;

CREATE ROLE all_upgradable_gucs_role;
ALTER ROLE all_upgradable_gucs_role SET allow_system_table_mods = true;
ALTER ROLE all_upgradable_gucs_role SET trace_notify = true;

CREATE ROLE some_nonupgradable_gucs_role;
ALTER ROLE some_nonupgradable_gucs_role SET allow_system_table_mods = true;
ALTER ROLE some_nonupgradable_gucs_role SET autocommit = true;

-- As exhaustive as possible within reason
CREATE ROLE all_nonupgradable_gucs_role;
ALTER ROLE all_nonupgradable_gucs_role SET autocommit = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET checkpoint_segments = 0;
-- ERROR:  parameter "checkpoint_segments" cannot be changed now
ALTER ROLE all_nonupgradable_gucs_role SET debug_latch = true;
ALTER ROLE all_nonupgradable_gucs_role SET dev_opt_unsafe_truncate_in_subtransaction = true;
ALTER ROLE all_nonupgradable_gucs_role SET dml_ignore_target_partition_check = true;
ALTER ROLE all_nonupgradable_gucs_role SET dtx_phase2_retry_count = 0;
ALTER ROLE all_nonupgradable_gucs_role SET enable_implicit_timeformat_YYYYMMDDHH24MISS = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_add_column_inherits_table_setting = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_allow_rename_relation_without_lock = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET gp_count_host_segments_using_address = true;
-- ERROR:  parameter "gp_count_host_segments_using_address" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role SET gp_distinct_grouping_sets_threshold = 32;
ALTER ROLE all_nonupgradable_gucs_role SET gp_eager_agg_distinct_pruning = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_eager_one_phase_agg = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_eager_preunique = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_exchange_default_partition = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_gpperfmon = true;
-- ERROR:  parameter "gp_enable_gpperfmon" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_groupext_distinct_gather = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_groupext_distinct_pruning = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_mdqa_shared_scan = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_mk_sort = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_motion_mk_sort = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_enable_sort_distinct = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_gang_creation_retry_non_recovery = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_gpperfmon_send_interval = 1;
ALTER ROLE all_nonupgradable_gucs_role SET gp_hashagg_default_nbatches = 32;
ALTER ROLE all_nonupgradable_gucs_role SET gp_hashagg_groups_per_bucket = 5;
ALTER ROLE all_nonupgradable_gucs_role SET gp_hashagg_streambottom = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_ignore_window_exclude = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_indexcheck_vacuum = 0;
ALTER ROLE all_nonupgradable_gucs_role SET gp_keep_all_xlog = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_keep_partition_children_locks = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_log_resqueue_priority_sleep_time = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_mk_sort_check = true;
ALTER ROLE all_nonupgradable_gucs_role SET gp_partitioning_dynamic_selection_log = true;
ALTER ROLE all_nonupgradable_gucs_role SET gpperfmon_log_alert_level = warning;
--ALTER ROLE all_nonupgradable_gucs_role SET gpperfmon_port = true;
-- ERROR:  parameter "gpperfmon_port" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role SET gp_perfmon_print_packet_info = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET gp_perfmon_segment_interval = true;
-- ERROR:  parameter "gp_perfmon_segment_interval" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role SET gp_resgroup_print_operator_memory_limits = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET gp_resource_group_cpu_ceiling_enforcement = true;
-- ERROR:  parameter "gp_resource_group_cpu_ceiling_enforcement" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role SET gp_resource_group_enable_recalculate_query_mem = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET gp_resource_group_memory_limit = true;
-- ERROR:  parameter "gp_resource_group_memory_limit" cannot be changed without restarting the server
-- ALTER ROLE all_nonupgradable_gucs_role SET gp_safefswritesize = true;
-- ERROR:  parameter "gp_safefswritesize" cannot be set after connection start
ALTER ROLE all_nonupgradable_gucs_role SET gp_sort_flags = 0;
ALTER ROLE all_nonupgradable_gucs_role SET gp_sort_max_distinct = 0;
ALTER ROLE all_nonupgradable_gucs_role SET gp_use_synchronize_seqscans_catalog_vacuum_full = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET max_appendonly_tables = true;
-- ERROR:  parameter "max_appendonly_tables" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role SET memory_spill_ratio = 0;
ALTER ROLE all_nonupgradable_gucs_role SET optimizer_analyze_enable_merge_of_leaf_stats = true;
ALTER ROLE all_nonupgradable_gucs_role SET optimizer_enable_dml_triggers = true;
ALTER ROLE all_nonupgradable_gucs_role SET optimizer_enable_partial_index = true;
ALTER ROLE all_nonupgradable_gucs_role SET optimizer_prune_unused_columns = true;
ALTER ROLE all_nonupgradable_gucs_role SET password_hash_algorithm = MD5;
ALTER ROLE all_nonupgradable_gucs_role SET sql_inheritance = true;
ALTER ROLE all_nonupgradable_gucs_role SET test_print_prefetch_joinqual = true;
-- ALTER ROLE all_nonupgradable_gucs_role SET wal_keep_segments = true;
-- ERROR:  parameter "wal_keep_segments" cannot be changed now

SELECT d.datname, r.rolname, split_part(unnest(s.setconfig),'=',1) AS guc
FROM pg_db_role_setting s
LEFT JOIN pg_roles r ON s.setrole = r.oid
LEFT JOIN pg_database d ON s.setdatabase = d.oid
WHERE r.rolname in ('all_upgradable_gucs_role', 'some_nonupgradable_gucs_role', 'all_nonupgradable_gucs_role')
OR d.datname in ('all_upgradable_gucs_db', 'some_nonupgradable_gucs_db', 'all_nonupgradable_gucs_db')
ORDER BY 1, 2, 3;

---------------------------------------------------------------------------------
--- Assert that pg_upgrade --check correctly detects the non-upgradeable objects
---------------------------------------------------------------------------------
!\retcode gpupgrade initialize --source-gphome="${GPHOME_SOURCE}" --target-gphome=${GPHOME_TARGET} --source-master-port=${PGPORT} --disk-free-ratio 0 --non-interactive;
! find $(ls -dt ~/gpAdminLogs/gpupgrade/pg_upgrade_*/ | head -1) -name "databases_and_roles_with_removed_gucs_set.txt" -exec cat {} +;

---------------------------------------------------------------------------------
--- Cleanup
---------------------------------------------------------------------------------
ALTER DATABASE all_upgradable_gucs_db RESET allow_system_table_mods;
ALTER DATABASE all_upgradable_gucs_db RESET trace_notify;

ALTER DATABASE some_nonupgradable_gucs_db RESET allow_system_table_mods;
ALTER DATABASE some_nonupgradable_gucs_db RESET autocommit;

ALTER DATABASE all_nonupgradable_gucs_db RESET autocommit;
ALTER DATABASE all_nonupgradable_gucs_db RESET debug_latch;

ALTER ROLE all_upgradable_gucs_role RESET allow_system_table_mods;
ALTER ROLE all_upgradable_gucs_role RESET trace_notify;

ALTER ROLE some_nonupgradable_gucs_role RESET allow_system_table_mods;
ALTER ROLE some_nonupgradable_gucs_role RESET autocommit;

ALTER ROLE all_nonupgradable_gucs_role RESET autocommit;
-- ALTER ROLE all_nonupgradable_gucs_role RESET checkpoint_segments;
-- ERROR:  parameter "checkpoint_segments" cannot be changed now
ALTER ROLE all_nonupgradable_gucs_role RESET debug_latch;
ALTER ROLE all_nonupgradable_gucs_role RESET dev_opt_unsafe_truncate_in_subtransaction;
ALTER ROLE all_nonupgradable_gucs_role RESET dml_ignore_target_partition_check;
ALTER ROLE all_nonupgradable_gucs_role RESET dtx_phase2_retry_count;
ALTER ROLE all_nonupgradable_gucs_role RESET enable_implicit_timeformat_YYYYMMDDHH24MISS;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_add_column_inherits_table_setting;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_allow_rename_relation_without_lock;
-- ALTER ROLE all_nonupgradable_gucs_role RESET gp_count_host_segments_using_address;
-- ERROR:  parameter "gp_count_host_segments_using_address" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role RESET gp_distinct_grouping_sets_threshold;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_eager_agg_distinct_pruning;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_eager_one_phase_agg;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_eager_preunique;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_exchange_default_partition;
-- ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_gpperfmon;
-- ERROR:  parameter "gp_enable_gpperfmon" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_groupext_distinct_gather;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_groupext_distinct_pruning;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_mdqa_shared_scan;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_mk_sort;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_motion_mk_sort;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_enable_sort_distinct;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_gang_creation_retry_non_recovery;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_gpperfmon_send_interval;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_hashagg_default_nbatches;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_hashagg_groups_per_bucket;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_hashagg_streambottom;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_ignore_window_exclude;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_indexcheck_vacuum;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_keep_all_xlog;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_keep_partition_children_locks;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_log_resqueue_priority_sleep_time;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_mk_sort_check;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_partitioning_dynamic_selection_log;
ALTER ROLE all_nonupgradable_gucs_role RESET gpperfmon_log_alert_level;
--ALTER ROLE all_nonupgradable_gucs_role RESET gpperfmon_port;
-- ERROR:  parameter "gpperfmon_port" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role RESET gp_perfmon_print_packet_info;
-- ALTER ROLE all_nonupgradable_gucs_role RESET gp_perfmon_segment_interval;
-- ERROR:  parameter "gp_perfmon_segment_interval" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role RESET gp_resgroup_print_operator_memory_limits;
-- ALTER ROLE all_nonupgradable_gucs_role RESET gp_resource_group_cpu_ceiling_enforcement;
-- ERROR:  parameter "gp_resource_group_cpu_ceiling_enforcement" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role RESET gp_resource_group_enable_recalculate_query_mem;
-- ALTER ROLE all_nonupgradable_gucs_role RESET gp_resource_group_memory_limit;
-- ERROR:  parameter "gp_resource_group_memory_limit" cannot be changed without restarting the server
-- ALTER ROLE all_nonupgradable_gucs_role RESET gp_safefswritesize;
-- ERROR:  parameter "gp_safefswritesize" cannot be set after connection start
ALTER ROLE all_nonupgradable_gucs_role RESET gp_sort_flags;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_sort_max_distinct;
ALTER ROLE all_nonupgradable_gucs_role RESET gp_use_synchronize_seqscans_catalog_vacuum_full;
-- ALTER ROLE all_nonupgradable_gucs_role RESET max_appendonly_tables;
-- ERROR:  parameter "max_appendonly_tables" cannot be changed without restarting the server
ALTER ROLE all_nonupgradable_gucs_role RESET memory_spill_ratio;
ALTER ROLE all_nonupgradable_gucs_role RESET optimizer_analyze_enable_merge_of_leaf_stats;
ALTER ROLE all_nonupgradable_gucs_role RESET optimizer_enable_dml_triggers;
ALTER ROLE all_nonupgradable_gucs_role RESET optimizer_enable_partial_index;
ALTER ROLE all_nonupgradable_gucs_role RESET optimizer_prune_unused_columns;
ALTER ROLE all_nonupgradable_gucs_role RESET password_hash_algorithm;
ALTER ROLE all_nonupgradable_gucs_role RESET sql_inheritance;
ALTER ROLE all_nonupgradable_gucs_role RESET test_print_prefetch_joinqual;
-- ALTER ROLE all_nonupgradable_gucs_role RESET wal_keep_segments;
-- ERROR:  parameter "wal_keep_segments" cannot be changed now

SELECT d.datname, r.rolname, split_part(unnest(s.setconfig),'=',1) AS guc
FROM pg_db_role_setting s
LEFT JOIN pg_roles r ON s.setrole = r.oid
LEFT JOIN pg_database d ON s.setdatabase = d.oid
WHERE r.rolname in ('all_upgradable_gucs_role', 'some_nonupgradable_gucs_role', 'all_nonupgradable_gucs_role')
OR d.datname in ('all_upgradable_gucs_db', 'some_nonupgradable_gucs_db', 'all_nonupgradable_gucs_db')
ORDER BY 1, 2, 3;

DROP DATABASE all_upgradable_gucs_db;
DROP DATABASE some_nonupgradable_gucs_db;
DROP DATABASE all_nonupgradable_gucs_db;

DROP ROLE all_upgradable_gucs_role;
DROP ROLE some_nonupgradable_gucs_role;
DROP ROLE all_nonupgradable_gucs_role;
