// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package gpupgrade_test

import (
	"path/filepath"
	"testing"

	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/testutils"
)

func TestPgUpgrade(t *testing.T) {
	// Since finalize archives the stateDir (GPUPGRADE_HOME) backups and
	// migration scripts cannot be stored here.
	stateDir := testutils.GetTempDir(t, "stateDir")
	defer testutils.MustRemoveAll(t, stateDir)

	resetEnv := testutils.SetEnv(t, "GPUPGRADE_HOME", stateDir)
	defer resetEnv()

	backupDir := testutils.GetTempDir(t, "backup")
	defer testutils.MustRemoveAll(t, backupDir)

	migrationDir := testutils.GetTempDir(t, "migration")
	defer testutils.MustRemoveAll(t, migrationDir)

	source := GetSourceCluster(t)
	dir := "6-to-7"
	if source.Version.Major == 5 {
		dir = "5-to-6"
	}

	testDir := filepath.Join(MustGetRepoRoot(t), "test", "acceptance", dir)
	sourceTestDir := filepath.Join(testDir, "migratable_tests", "source_cluster_regress")
	targetTestDir := filepath.Join(testDir, "migratable_tests", "target_cluster_regress")

	testutils.MustApplySQLFile(t, GPHOME_SOURCE, PGPORT, filepath.Join(testDir, "setup_globals.sql"))
	defer testutils.MustApplySQLFile(t, GPHOME_SOURCE, PGPORT, filepath.Join(testDir, "teardown_globals.sql"))

	t.Run("migration scripts generate sql to modify non-upgradeable objects and fix pg_upgrade check errors", func(t *testing.T) {
		backupDemoCluster(t, backupDir, source)
		defer restoreDemoCluster(t, backupDir, source, GetTempTargetCluster(t))

		opts := isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      sourceTestDir,
			outputDir:     sourceTestDir,
			schedule:      idl.Schedule_migratable_source_schedule,
		}
		isolation2_regress(t, opts)

		generate(t, migrationDir)
		apply(t, GPHOME_SOURCE, PGPORT, idl.Step_initialize, migrationDir)

		initialize(t, idl.Mode_link)
		defer revertIgnoreFailures(t) // cleanup in case we fail part way through
		execute(t)
		finalize(t)

		apply(t, GPHOME_TARGET, PGPORT, idl.Step_finalize, migrationDir)

		outputTestDir := filepath.Join(targetTestDir, "finalize")
		testutils.MustCreateDir(t, outputTestDir)
		opts = isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_TARGET,
			port:          PGPORT,
			inputDir:      targetTestDir,
			outputDir:     outputTestDir,
			schedule:      idl.Schedule_migratable_target_schedule,
		}
		isolation2_regress(t, opts)
	})

	t.Run("recreate scripts restore migratable objects when reverting after initialize", func(t *testing.T) {
		opts := isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      sourceTestDir,
			outputDir:     sourceTestDir,
			schedule:      idl.Schedule_migratable_source_schedule,
		}
		isolation2_regress(t, opts)

		generate(t, migrationDir)
		apply(t, GPHOME_SOURCE, PGPORT, idl.Step_initialize, migrationDir)

		initialize(t, idl.Mode_link)
		defer revertIgnoreFailures(t) // cleanup in case we fail part way through
		revert(t)

		apply(t, GPHOME_TARGET, PGPORT, idl.Step_revert, migrationDir)

		outputTestDir := filepath.Join(targetTestDir, "revert_initialize")
		testutils.MustCreateDir(t, outputTestDir)
		opts = isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      targetTestDir,
			outputDir:     outputTestDir,
			schedule:      idl.Schedule_migratable_target_schedule,
		}
		isolation2_regress(t, opts)
	})

	t.Run("recreate scripts restore migratable objects when reverting after execute", func(t *testing.T) {
		opts := isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      sourceTestDir,
			outputDir:     sourceTestDir,
			schedule:      idl.Schedule_migratable_source_schedule,
		}
		isolation2_regress(t, opts)

		generate(t, migrationDir)
		apply(t, GPHOME_SOURCE, PGPORT, idl.Step_initialize, migrationDir)

		initialize(t, idl.Mode_link)
		defer revertIgnoreFailures(t) // cleanup in case we fail part way through
		execute(t)
		revert(t)

		apply(t, GPHOME_TARGET, PGPORT, idl.Step_revert, migrationDir)

		outputTestDir := filepath.Join(targetTestDir, "revert_execute")
		testutils.MustCreateDir(t, outputTestDir)
		opts = isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      targetTestDir,
			outputDir:     outputTestDir,
			schedule:      idl.Schedule_migratable_target_schedule,
		}
		isolation2_regress(t, opts)
	})

	t.Run("pg_upgrade upgradeable tests", func(t *testing.T) {
		sourceTestDir := filepath.Join(testDir, "upgradeable_tests", "source_cluster_regress")
		opts := isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      sourceTestDir,
			outputDir:     sourceTestDir,
			schedule:      idl.Schedule_upgradeable_source_schedule,
		}
		isolation2_regress(t, opts)

		initialize(t, idl.Mode_link)
		defer revert(t)
		execute(t)

		targetTestDir := filepath.Join(testDir, "upgradeable_tests", "target_cluster_regress")
		opts = isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_TARGET,
			port:          TARGET_PGPORT,
			inputDir:      targetTestDir,
			outputDir:     targetTestDir,
			schedule:      idl.Schedule_upgradeable_target_schedule,
		}
		isolation2_regress(t, opts)
	})

	t.Run("pg_upgrade --check detects non-upgradeable objects", func(t *testing.T) {
		nonUpgradeableTestDir := filepath.Join(testDir, "non_upgradeable_tests")
		opts := isolationOptions{
			sourceVersion: source.Version,
			gphome:        GPHOME_SOURCE,
			port:          PGPORT,
			inputDir:      nonUpgradeableTestDir,
			outputDir:     nonUpgradeableTestDir,
			schedule:      idl.Schedule_non_upgradeable_schedule,
		}
		isolation2_regress(t, opts)

		revert(t)
	})

}
