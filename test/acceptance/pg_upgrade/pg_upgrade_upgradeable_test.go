// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package pg_upgrade_test

import (
	"path/filepath"
	"testing"

	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/testutils"
	"github.com/greenplum-db/gpupgrade/testutils/acceptance"
)

func Test_PgUpgrade_Upgradeable_Tests(t *testing.T) {
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

	source := acceptance.GetSourceCluster(t)
	dir := "6-to-7"
	if source.Version.Major == 5 {
		dir = "5-to-6"
	} else {
		// Disables 6 > 7 upgradable tests in the pipeline. Because gpugprade
		// does not work for 6 > 7, but we want to excercise pg_upgrade non
		// upgradable tests.
		return
	}

	testDir := filepath.Join(acceptance.MustGetRepoRoot(t), "test", "acceptance", "pg_upgrade", dir)
	testutils.MustApplySQLFile(t, acceptance.GPHOME_SOURCE, acceptance.PGPORT, filepath.Join(testDir, "setup_globals.sql"))
	defer testutils.MustApplySQLFile(t, acceptance.GPHOME_SOURCE, acceptance.PGPORT, filepath.Join(testDir, "teardown_globals.sql"))

	acceptance.SetupDummyGpToolKit(t, source.Version)
	defer acceptance.TeardownDummyGpToolKit(t, source.Version)

	t.Run("pg_upgrade upgradeable tests", func(t *testing.T) {
		acceptance.BackupDemoCluster(t, backupDir, source)
		defer acceptance.RestoreDemoCluster(t, backupDir, source, acceptance.GetTempTargetCluster(t))

		sourceTestDir := filepath.Join(testDir, "upgradeable_tests", "source_cluster_regress")
		acceptance.Isolation2_regress(t, source.Version, acceptance.GPHOME_SOURCE, acceptance.PGPORT, sourceTestDir, sourceTestDir, idl.Schedule_upgradeable_source_schedule)

		// 6 > 7 FIXME: gpupgrade generate and apply currently use plpythonu
		// which is triggering failure when dumping and restoring because it is
		// trying to bring back plython2. Since there are no data-migration
		// script for 6 > 7 yet, disabling the generate and apply commands is a
		// temporary woraround.
		if source.Version.Major == 5 {
			acceptance.Generate(t, migrationDir)
			acceptance.Apply(t, acceptance.GPHOME_SOURCE, acceptance.PGPORT, idl.Step_initialize, migrationDir)
		}

		// 6 > 7 FIXME: gpupgrade finalize for 6 > 7 in link mode is currently
		// broken. There is an issue when trying to startup the cluster after
		// rsyncing mirrors to the intermediate cluster. Copy mode makes new
		// mirrors from scratch using which is working.
		if source.Version.Major == 5 {
			acceptance.Initialize(t, idl.Mode_link)
		} else {
			acceptance.Initialize(t, idl.Mode_copy)
		}
		defer acceptance.RevertIgnoreFailures(t)
		acceptance.Execute(t)
		acceptance.Finalize(t)

		// 6 > 7 FIXME: gpupgrade generate and apply currently use plpythonu
		// which is triggering failure when dumping and restoring because it is
		// trying to bring back plython2. Since there are no data-migration
		// script for 6 > 7 yet, disabling the generate and apply commands is a
		// temporary woraround.
		if source.Version.Major == 5 {
			acceptance.Apply(t, acceptance.GPHOME_TARGET, acceptance.PGPORT, idl.Step_finalize, migrationDir)
		}

		targetTestDir := filepath.Join(testDir, "upgradeable_tests", "target_cluster_regress")
		acceptance.Isolation2_regress(t, source.Version, acceptance.GPHOME_SOURCE, acceptance.PGPORT, targetTestDir, targetTestDir, idl.Schedule_upgradeable_target_schedule)
	})
}
