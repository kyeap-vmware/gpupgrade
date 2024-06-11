// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package hub

import (
	"fmt"
	"os"
	"path/filepath"
	"strconv"

	"golang.org/x/xerrors"

	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/step"
	"github.com/greenplum-db/gpupgrade/upgrade"
	"github.com/greenplum-db/gpupgrade/utils"
	"github.com/greenplum-db/gpupgrade/utils/errorlist"
	"github.com/greenplum-db/gpupgrade/utils/rsync"
)

// format of yyyyMMddTHHmmss
const TimeStringFormat = "20060102T150405"

func UpgradeCoordinator(streams step.OutStreams, backupDir string, pgUpgradeVerbose bool, skipPgUpgradeChecks bool, jobs uint, source *greenplum.Cluster, intermediate *greenplum.Cluster, action idl.PgOptions_Action, mode idl.Mode, pgUpgradeTimestamp string) error {
	oldOptions := ""
	// When upgrading from 5 the coordinator must be provided with its standby's dbid to allow WAL to sync.
	if source.Version.Major == 5 && source.HasStandby() {
		oldOptions = fmt.Sprintf("-x %d", source.Standby().DbID)
	}

	opts := &idl.PgOptions{
		BackupDir:           backupDir,
		PgUpgradeVerbose:    pgUpgradeVerbose,
		SkipPgUpgradeChecks: skipPgUpgradeChecks,
		Jobs:                strconv.FormatUint(uint64(jobs), 10),
		Action:              action,
		Role:                intermediate.Coordinator().Role,
		ContentID:           int32(intermediate.Coordinator().ContentID),
		PgUpgradeMode:       idl.PgOptions_dispatcher,
		OldOptions:          oldOptions,
		Mode:                mode,
		TargetVersion:       intermediate.Version.String(),
		OldBinDir:           filepath.Join(source.GPHome, "bin"),
		OldDataDir:          source.CoordinatorDataDir(),
		OldPort:             strconv.Itoa(source.CoordinatorPort()),
		OldDBID:             strconv.Itoa(source.Coordinator().DbID),
		NewBinDir:           filepath.Join(intermediate.GPHome, "bin"),
		NewDataDir:          intermediate.CoordinatorDataDir(),
		NewPort:             strconv.Itoa(intermediate.CoordinatorPort()),
		NewDBID:             strconv.Itoa(intermediate.Coordinator().DbID),
		PgUpgradeTimestamp:  pgUpgradeTimestamp,
	}

	err := RsyncCoordinatorDataDir(streams, utils.GetCoordinatorPreUpgradeBackupDir(backupDir), intermediate.CoordinatorDataDir())
	if err != nil {
		return err
	}

	err = upgrade.Run(streams.Stdout(), streams.Stderr(), opts)
	if err != nil {
		if opts.Action != idl.PgOptions_check {
			return xerrors.Errorf("%s master: %v", action, err)
		}

		pgUpgradeDir, dirErr := utils.GetPgUpgradeDir(opts.GetRole(), opts.GetContentID(), opts.GetPgUpgradeTimeStamp(), opts.GetTargetVersion())
		if dirErr != nil {
			err = errorlist.Append(err, dirErr)
		}

		generatedScriptsOutputDir, scriptsDirErr := utils.GetDefaultGeneratedDataMigrationScriptsDir()
		if scriptsDirErr != nil {
			err = errorlist.Append(err, scriptsDirErr)
		}

		nextAction := fmt.Sprintf(`Consult the pg_upgrade check output files located: %s
Refer to the gpupgrade documentation for details on the pg_upgrade check error.

If you haven't already run the "initialize" data migration scripts with
"gpupgrade initialize" or "gpupgrade apply --gphome %s --port %d --input-dir %s --phase initialize"

To connect to the intermediate target cluster:
source %s
MASTER_DATA_DIRECTORY=%s
PGPORT=%d`, pgUpgradeDir,
			source.GPHome, source.CoordinatorPort(), generatedScriptsOutputDir,
			filepath.Join(intermediate.GPHome, "greenplum_path.sh"), intermediate.CoordinatorDataDir(), intermediate.CoordinatorPort())

		return utils.NewNextActionErr(xerrors.Errorf("%s master: %v", action, err), nextAction)
	}

	return nil
}

func RsyncCoordinatorDataDir(stream step.OutStreams, sourceDir, targetDir string) error {
	sourceDirRsync := filepath.Clean(sourceDir) + string(os.PathSeparator)

	options := []rsync.Option{
		rsync.WithSources(sourceDirRsync),
		rsync.WithDestination(targetDir),
		rsync.WithOptions("--archive", "--delete"),
		rsync.WithExcludedFiles("pg_log/*"),
		rsync.WithStream(stream),
	}

	err := rsync.Rsync(options...)
	if err != nil {
		return xerrors.Errorf("rsync %q to %q: %w", sourceDirRsync, targetDir, err)
	}

	return nil
}
