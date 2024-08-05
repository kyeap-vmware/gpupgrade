// Copyright (c) 2017-2024 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package greenplum

import (
	"database/sql"
	"fmt"
	"io"
	"log"

	"github.com/greenplum-db/gpupgrade/utils"
	"github.com/greenplum-db/gpupgrade/utils/errorlist"
	"github.com/vbauerster/mpb/v8"
	"golang.org/x/xerrors"
)

const (
	analyzeDataTablesQuery = `
WITH all_tables AS (
  SELECT c.oid, n.nspname, c.relname
  FROM pg_class c
  JOIN pg_namespace n ON n.oid=c.relnamespace
  WHERE (c.relkind='r'::char OR c.relkind = 'm'::char)
  AND (c.relnamespace >= 16384 OR n.nspname = 'public' OR n.nspname = 'pg_catalog')
  AND c.oid NOT IN (SELECT reloid FROM pg_exttable)
),
midlevel_partitions AS (
  SELECT c.oid, n.nspname,
  c.relname
  FROM pg_class c
  LEFT JOIN pg_partition_rule pr ON pr.parchildrelid=c.oid
  LEFT JOIN pg_partition p ON p.oid=pr.paroid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE p.parrelid != 0 AND c.relhassubclass='t'
),
root_partitions AS (
SELECT DISTINCT c.oid, n.nspname, c.relname
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN pg_partition p ON p.parrelid=c.oid
WHERE p.paristemplate = false
)
SELECT 'ANALYZE ' || quote_ident(nspname) || '.' || quote_ident(relname) || ';' AS analyze_command
FROM all_tables
WHERE oid NOT IN (SELECT oid FROM midlevel_partitions)
AND oid NOT IN (SELECT oid FROM root_partitions);
`
	analyzeRootPartitionsQuery = `
SELECT DISTINCT 'ANALYZE ROOTPARTITION ' || quote_ident(n.nspname) || '.' || quote_ident(c.relname) || ';' AS analyzeroot_command
FROM pg_class c
JOIN pg_namespace n ON n.oid=c.relnamespace
JOIN pg_partition p ON p.parrelid=c.oid
WHERE p.paristemplate = false
`
)

// Reindexes the indexes invalidated by pg_upgrade during the execute phase.
// Refer to the following pg_upgrade functions:
// old_8_3_invalidate_bpchar_pattern_ops_indexes
// old_8_3_invalidate_ao_indexes
// old_8_3_invalidate_bitmap_indexes
func ReindexInvalidIndexes(target *Cluster, jobs int32, output io.Writer) error {
	var err error

	if target.Version.Major != 6 {
		return xerrors.Errorf("reindex invalid indexes should only be executed on a GPDB6 target cluster") 
	}

	databases, err := target.GetDatabases()
	if err != nil {
		return err
	}

	progressBar := mpb.New(mpb.WithOutput(output), mpb.WithAutoRefresh(), mpb.WithWidth(80))

	for _, database := range databases {
		err = ReindexDatabase(target, database, jobs, progressBar)
		if err != nil {
			return err
		}
	}

	progressBar.Wait()
	return nil
}

func ReindexDatabase(target *Cluster, database string, jobs int32, progressBar *mpb.Progress) error {
	db, err := sql.Open("pgx", target.Connection(Database(database)))
	if err != nil {
		return err
	}
	defer func() {
		if cErr := db.Close(); cErr != nil {
			err = errorlist.Append(err, cErr)
		}
	}()

	reindexCommands, err := getReindexCommands(db)
	if err != nil {
		return err
	}
	if len(reindexCommands) == 0 {
		log.Printf("No invalid indexes found in database %s", database)
		return nil
	}

	bar := utils.AddBar(progressBar, len(reindexCommands), fmt.Sprintf("Database: %s", database))
		
	err = ExecuteCommands(target, database, reindexCommands, jobs, bar)
	if err != nil {
		bar.Abort(false)
		return err
	}

	return nil
}

func getReindexCommands(db *sql.DB) ([]string, error) {
	var reindexCommands []string

	invalidIndexesQuery := `
	SELECT 
	'REINDEX INDEX ' || quote_ident(n.nspname) || '.' || quote_ident(c1.relname) || ';' as command
	FROM pg_catalog.pg_class c1
	JOIN pg_index i on i.indexrelid=c1.oid
	JOIN pg_namespace n on n.oid=c1.relnamespace
	WHERE indisvalid=false;`

	rows, err := db.Query(invalidIndexesQuery)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		var command string
		err = rows.Scan(&command)
		if err != nil {
			return nil, err
		}
		reindexCommands = append(reindexCommands, command)
	}

	err = rows.Err()
	if err != nil {
		return nil, err
	}

	return reindexCommands, nil
}


// Rebuilds the tsvector tables in the cluster.
// Refer to pg_upgrade:old_8_3_rebuild_tsvector_tables
func RebuildTSVectorTables(target *Cluster, jobs int32, output io.Writer) error {
	var err error

	if target.Version.Major != 6 {
		return xerrors.Errorf("rebuild tsvector tables should only be executed on a GPDB6 target cluster")
	}

	databases, err := target.GetDatabases()
	if err != nil {
		return err
	}

	progressBar := utils.NewProgressBar(output)

	for _, database := range databases {
		err = RebuildTSVectorTablesForDatabase(target, database, jobs, progressBar)
		if err != nil {
			return err
		}
	}

	progressBar.Wait()
	return nil
}

func RebuildTSVectorTablesForDatabase(target *Cluster, database string, jobs int32, progressBar *mpb.Progress) error {
	db, err := sql.Open("pgx", target.Connection(Database(database)))
	if err != nil {
		return err
	}
	defer func() {
		if cErr := db.Close(); cErr != nil {
			err = errorlist.Append(err, cErr)
		}
	}()

	tsVectorCommands, err := getTSVectorCommands(db)
	if err != nil {
		return err
	}
	if len(tsVectorCommands) == 0 {
		log.Printf("No tsvector columns found in database %s", database)
		return nil
	}

	bar := utils.AddBar(progressBar, len(tsVectorCommands), fmt.Sprintf("Database: %s", database))

	err = ExecuteCommands(target, database, tsVectorCommands, jobs, bar)
	if err != nil {
		bar.Abort(false)
		return err
	}

	return nil
}

// If the tsvector column has indexes, we must first drop them
// before running the ALTER COLUMN TYPE command because GPDB6
// does not allow ALTER TYPE on an indexed column.
// After rebuilding the column, we recreate them.
func getTSVectorCommands(db *sql.DB) ([]string, error) {
	var commands []string
	var tsvectorRes struct {
		Schema    string
		Relname   string
		Attname   string
		IndexName sql.NullString
		IndexDef  sql.NullString
	}

	query := `
	SELECT n.nspname, 
	c.relname, a.attname, 
	i.indexrelid::regclass as indexname, 
	pg_get_indexdef(i.indexrelid) as indexdef
	FROM pg_catalog.pg_class c
	JOIN pg_catalog.pg_namespace n on n.oid = c.relnamespace
	JOIN pg_catalog.pg_attribute a on a.attrelid=c.oid
	LEFT JOIN pg_index i on i.indrelid=c.oid
	WHERE c.relkind = 'r' AND
	NOT a.attisdropped AND
	a.attinhcount = 0 AND
	a.atttypid = 'pg_catalog.tsvector'::pg_catalog.regtype AND
	n.nspname !~ '^pg_temp_' AND
	n.nspname !~ '^pg_toast_temp_' AND
	n.nspname NOT IN ('pg_catalog', 'information_schema');
`
	rows, err := db.Query(query)
	if err != nil {
		return nil, err
	}
	defer rows.Close()

	for rows.Next() {
		err = rows.Scan(&tsvectorRes.Schema,
			&tsvectorRes.Relname,
			&tsvectorRes.Attname,
			&tsvectorRes.IndexName,
			&tsvectorRes.IndexDef)
		if err != nil {
			return nil, err
		}
		command := ""
		if tsvectorRes.IndexName.Valid {
			command += fmt.Sprintf("DROP INDEX %s;\n", tsvectorRes.IndexName.String)
		}

		command += fmt.Sprintf(
			"ALTER TABLE %s.%s\nALTER COLUMN %s TYPE pg_catalog.tsvector USING %s::pg_catalog.text::pg_catalog.tsvector;\n",
			tsvectorRes.Schema, tsvectorRes.Relname, tsvectorRes.Attname, tsvectorRes.Attname)

		if tsvectorRes.IndexName.Valid {
			command += fmt.Sprintf("%s;\n", tsvectorRes.IndexDef.String)
		}
	
		commands = append(commands, command)
	}

	err = rows.Err()
	if err != nil {
		return nil, err
	}
	return commands, nil
}


func AnalyzeCluster(target *Cluster, jobs int32, output io.Writer) error {
	var err error

	databases, err := target.GetDatabases()
	if err != nil {
		return err
	}

	progressBar := mpb.New(mpb.WithOutput(output), mpb.WithAutoRefresh(), mpb.WithWidth(80))

	for _, database := range databases {
		err := AnalyzeDatabase(target, database, jobs, progressBar)
		if err != nil {
			return err
		}
	}

	progressBar.Wait()
	return nil
}

func AnalyzeDatabase(target *Cluster, database string, jobs int32, progressBar *mpb.Progress) error {
	// 6 > 7 FIXME: The analyze query needs to be adapted for 7x. The GUC
	// optimizer_analyze_enable_merge_of_leaf_stats is also removed in 7x.
	// Evaluate if guc is still needed. Temporary disable to get pg_upgrade
	// upgradable testing working.
	if target.Version.Major != 6 {
		return nil
	}

	var err error
	var dataTableCmds []string
	var rootPartitionCmds []string

	db, err := sql.Open("pgx", target.Connection(Database(database)))
	if err != nil {
		return err
	}
	defer func() {
		if cErr := db.Close(); cErr != nil {
			err = errorlist.Append(err, cErr)
		}
	}()

	// Get the analyze commands for the data tables and root partitions
	rows, err := db.Query(analyzeDataTablesQuery)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var command string
		err = rows.Scan(&command)
		if err != nil {
			return err
		}
		dataTableCmds = append(dataTableCmds, command)
	}

	rows, err = db.Query(analyzeRootPartitionsQuery)
	if err != nil {
		return err
	}
	defer rows.Close()

	for rows.Next() {
		var command string
		err = rows.Scan(&command)
		if err != nil {
			return err
		}
		rootPartitionCmds = append(rootPartitionCmds, command)
	}

	bar := utils.AddBar(progressBar, len(dataTableCmds) + len(rootPartitionCmds), fmt.Sprintf("Database: %s", database))

	// Analyze the data tables first, then the root partitions.
	// Suppress generating root stats for every partition.
	err = ExecuteCommands(target, database, dataTableCmds, jobs, bar, "set optimizer_analyze_enable_merge_of_leaf_stats=off;")
	if err != nil {
		bar.Abort(false)
		return err
	}

	err = ExecuteCommands(target, database, rootPartitionCmds, jobs, bar)
	if err != nil {
		bar.Abort(false)
		return err
	}

	return nil
}
