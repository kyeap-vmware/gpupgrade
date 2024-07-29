// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package commands

import (
	"errors"
	"fmt"
	"path/filepath"

	"github.com/spf13/cobra"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"

	"github.com/greenplum-db/gpupgrade/cli/clistep"
	"github.com/greenplum-db/gpupgrade/cli/commanders"
	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/step"
	"github.com/greenplum-db/gpupgrade/upgrade"
	"github.com/greenplum-db/gpupgrade/utils"
)

func finalize() *cobra.Command {
	var verbose bool
	var nonInteractive bool
	var jobs uint

	cmd := &cobra.Command{
		Use:   "finalize",
		Short: "finalizes the cluster after upgrade execution",
		Long:  FinalizeHelp,
		RunE: func(cmd *cobra.Command, args []string) (err error) {
			var response *idl.FinalizeResponse

			logdir, err := utils.GetLogDir()
			if err != nil {
				return err
			}

			confirmationText := fmt.Sprintf(finalizeConfirmationText,
				cases.Title(language.English).String(idl.Step_finalize.String()),
				finalizeSubsteps, logdir)

			st, err := clistep.Begin(idl.Step_finalize, verbose, nonInteractive, confirmationText)
			if err != nil {
				if errors.Is(err, step.Quit) {
					// If user cancels don't return an error to main to avoid
					// printing "Error:".
					return nil
				}
				return err
			}

			target := &greenplum.Cluster{}
			st.RunHubSubstep(func(streams step.OutStreams) error {
				client, err := connectToHub()
				if err != nil {
					return err
				}

				response, err = commanders.Finalize(client, verbose)
				if err != nil {
					return err
				}

				target, err = greenplum.DecodeCluster(response.GetTarget())
				if err != nil {
					return err
				}

				return nil
			})

			st.Run(idl.Substep_stop_hub_and_agents, func(streams step.OutStreams) error {
				return stopHubAndAgents()
			})

			st.AlwaysRun(idl.Substep_execute_finalize_data_migration_scripts, func(streams step.OutStreams) error {
				if nonInteractive {
					return nil
				}

				currentDir := filepath.Join(response.GetLogArchiveDirectory(), "data-migration-scripts", "current")
				return commanders.ApplyDataMigrationScripts(streams, nonInteractive, target.GPHome, target.CoordinatorPort(),
					response.GetLogArchiveDirectory(), utils.System.DirFS(currentDir), currentDir, idl.Step_finalize)
			})

			st.Run(idl.Substep_analyze_target_cluster, func(streams step.OutStreams) error {
				if !nonInteractive {
					fmt.Println()
					fmt.Println(`
It is strongly recommended to create optimizer statistics to ensure performant operations. 
However, this could take quite awhile and you may need your cluster now.
If you postpone creating statistics then after the upgrade run "vacuumdb --all --analyze-in-stages".`)
					fmt.Println()

					prompt := "Create optimizer statistics now?  Yy|Nn: "
					err = clistep.Prompt(utils.StdinReader, prompt)
					if err != nil {
						if errors.Is(err, step.Quit) {
							return nil // Continue with upgrade even if user skips creating statistics
						}
						return err
					}
				}

				return target.RunGreenplumCmd(streams, "vacuumdb", "--all", "--analyze-only")
			})

			st.Run(idl.Substep_delete_master_statedir, func(streams step.OutStreams) error {
				// Removing the state directory removes the step status file.
				// Disable the store so the step framework does not try to write
				// to a non-existent status file.
				st.DisableStore()
				return upgrade.DeleteDirectories([]string{utils.GetStateDir()}, upgrade.StateDirectoryFiles, streams)
			})

			return st.Complete(fmt.Sprintf(FinalizeCompletedText,
				target.Version,
				fmt.Sprintf("%s.<contentID>%s", response.GetUpgradeID(), upgrade.OldSuffix),
				response.GetArchivedSourceCoordinatorDataDirectory(),
				response.GetLogArchiveDirectory(),
				filepath.Join(target.GPHome, "greenplum_path.sh"),
				filepath.Join(filepath.Dir(target.GPHome), "greenplum-db"), target.GPHome,
				filepath.Join(target.GPHome, "greenplum_path.sh"),
				target.CoordinatorDataDir(),
				target.CoordinatorPort(),
				idl.Step_finalize,
				target.GPHome, target.CoordinatorPort(), filepath.Join(response.GetLogArchiveDirectory(), "data-migration-scripts"), idl.Step_finalize,
			))
		},
	}

	cmd.Flags().BoolVarP(&verbose, "verbose", "v", false, "print the output stream from all substeps")
	cmd.Flags().BoolVar(&nonInteractive, "non-interactive", false, "do not prompt for confirmation to proceed")
	cmd.Flags().MarkHidden("non-interactive") //nolint
	cmd.Flags().UintVar(&jobs, "jobs", 4, "number of jobs to run for steps that can run in parallel. Defaults to 4.")
	return addHelpToCommand(cmd, FinalizeHelp)
}
