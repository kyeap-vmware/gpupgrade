// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package integration_test

import (
	"database/sql"
	"fmt"
	"reflect"
	"testing"

	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/testutils"
)

func TestReindex(t *testing.T) {
	t.Run("GetReindexCommands reorders reindex on tables partitioned date so most recent partitions are done first", func(t *testing.T) {
		testdb := "integration_reindex_test"
		postgresConnStr := testutils.GetConnStrFromEnv(t, "postgres")
		testutils.MustExecuteSQL(t, postgresConnStr, fmt.Sprintf(`CREATE DATABASE %s`, testdb))
		defer testutils.MustExecuteSQL(t, postgresConnStr, fmt.Sprintf(`DROP DATABASE %s`, testdb))

		connStr := testutils.GetConnStrFromEnv(t, testdb)
		testutils.MustExecuteSQL(t, connStr, `
			CREATE TABLE public.sales (date date)
			WITH (appendonly=true)
			DISTRIBUTED BY (date)
			PARTITION BY RANGE (date)
			(START (date '2000-01-01') END (date '2001-01-01') EVERY (INTERVAL '1 month'));
		`)
		testutils.MustExecuteSQL(t, connStr, `CREATE INDEX sales_idx on public.sales(date);`)

		testutils.MustExecuteSQL(t, connStr, `
			SET search_path to public;
			SET allow_system_table_mods=dml;
			UPDATE pg_index
			SET
				indisvalid = 'f'
			WHERE indexrelid::regclass::text LIKE 'sales%';
		`)

		testDBConn, err := sql.Open("pgx", connStr)
		if err != nil {
			t.Fatalf("err: %s", err)
		}
		defer testDBConn.Close()

		expectedReindexCmds := []string{
			"REINDEX INDEX public.sales_idx_1_prt_12;",
			"REINDEX INDEX public.sales_idx_1_prt_11;",
			"REINDEX INDEX public.sales_idx_1_prt_10;",
			"REINDEX INDEX public.sales_idx_1_prt_9;",
			"REINDEX INDEX public.sales_idx_1_prt_8;",
			"REINDEX INDEX public.sales_idx_1_prt_7;",
			"REINDEX INDEX public.sales_idx_1_prt_6;",
			"REINDEX INDEX public.sales_idx_1_prt_5;",
			"REINDEX INDEX public.sales_idx_1_prt_4;",
			"REINDEX INDEX public.sales_idx_1_prt_3;",
			"REINDEX INDEX public.sales_idx_1_prt_2;",
			"REINDEX INDEX public.sales_idx_1_prt_1;",
			"REINDEX INDEX public.sales_idx;",
		}
		resultReindexCmds, err := greenplum.GetReindexCommands(testDBConn)
		if err != nil {
			t.Fatalf("err: %s", err)
		}
		if !reflect.DeepEqual(expectedReindexCmds, resultReindexCmds) {
			t.Fatalf("Expected vs Actual mismatch\nExpected:\n%s\n\nActual:\n%s\n", expectedReindexCmds, resultReindexCmds)
		}
	})
}
