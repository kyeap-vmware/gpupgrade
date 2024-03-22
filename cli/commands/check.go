// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package commands

import (
	"fmt"
	"os"
	"os/exec"
	"path"
	"strconv"

	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/greenplum/connection"
	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/utils"
	"github.com/greenplum-db/gpupgrade/utils/errorlist"
	"github.com/spf13/cobra"
)

func check() *cobra.Command {
	var sourceGPHome string
	var targetGPHome string
	var sourcePort int

	cmd := &cobra.Command{
		Use:   "check",
		Short: "Executes a subset of pg_upgrade checks for upgrade from GPDB6 to GPDB7",
		Long:  CheckHelp,
		PreRunE: func(cmd *cobra.Command, args []string) error {
			_, err := os.Stat(sourceGPHome)
			if os.IsNotExist(err) {
				return fmt.Errorf(`source GPHOME "%s" does not exist`, sourceGPHome)
			}
			_, err = os.Stat(targetGPHome)
			if os.IsNotExist(err) {
				return fmt.Errorf(`target GPHOME "%s" does not exist`, targetGPHome)
			}

			return nil
		},
		RunE: func(cmd *cobra.Command, args []string) (err error) {
			// Get connection to db to get cluster info
			db, err := connection.Bootstrap(idl.ClusterDestination_source, sourceGPHome, sourcePort)
			if err != nil {
				return err
			}
			defer func() {
				if cErr := db.Close(); cErr != nil {
					err = errorlist.Append(err, cErr)
				}
			}()

			source, err := greenplum.ClusterFromDB(db, sourceGPHome, idl.ClusterDestination_source)
			if err != nil {
				return err
			}

			if source.Version.Major != 6 {
				return fmt.Errorf(`Your cluster version was detected as %s. This command only runs only runs on gpdb6 to look for objects incompatible with GPDB7. `, source.Version.String())
			}

			const TimeStringFormat = "20060102T150405"
			pgUpgradeTimestamp := utils.System.Now().Format(TimeStringFormat)
			pgUpgradeDir, err := utils.GetPgUpgradeDir(greenplum.PrimaryRole, -1, pgUpgradeTimestamp, "7.0.0")
			if err != nil {
				return err
			}

			err = utils.System.MkdirAll(pgUpgradeDir, 0700)
			if err != nil {
				return err
			}

			pgUpgradeArgs := []string{
				"-c",
				"--continue-check-on-fatal",
				"--retain",
				"--output-dir", pgUpgradeDir,
				"-d", source.CoordinatorDataDir(),
				"-b", path.Join(sourceGPHome, "bin"),
				"-p", strconv.Itoa(sourcePort),
				"--check-not-in-place",
			}

			pgUpgradeBinary := path.Join(targetGPHome, "bin", "pg_upgrade")
			command := exec.Command(pgUpgradeBinary, pgUpgradeArgs...)
			command.Stdout = os.Stdout
			command.Stderr = os.Stderr

			pgUpgradeErr := command.Run()
			if err != nil {
				return pgUpgradeErr
			}
			return nil
		},
	}

	cmd.Flags().StringVar(&sourceGPHome, "source-gphome", "/usr/local/gpdb6", "path for the source Greenplum installation")
	cmd.Flags().StringVar(&targetGPHome, "target-gphome", "/usr/local/gpdb7", "path for the target Greenplum installation")
	cmd.Flags().IntVar(&sourcePort, "source-master-port", 5432, "master port for source gpdb cluster")

	return addHelpToCommand(cmd, CheckHelp)
}
