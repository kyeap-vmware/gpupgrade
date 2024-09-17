// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package commands

import (
	"bufio"
	"database/sql"
	"errors"
	"fmt"
	"log"
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/olekukonko/tablewriter"
	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"golang.org/x/text/cases"
	"golang.org/x/text/language"
	"golang.org/x/xerrors"

	"github.com/greenplum-db/gpupgrade/cli/clistep"
	"github.com/greenplum-db/gpupgrade/cli/commanders"
	"github.com/greenplum-db/gpupgrade/config"
	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/greenplum/connection"
	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/step"
	"github.com/greenplum-db/gpupgrade/upgrade"
	"github.com/greenplum-db/gpupgrade/utils"
	"github.com/greenplum-db/gpupgrade/utils/errorlist"
	"github.com/greenplum-db/gpupgrade/utils/logger"
)

func initialize() *cobra.Command {
	var file string
	var nonInteractive bool
	var sourceGPHome, targetGPHome string
	var sourcePort int
	var hubPort int
	var agentPort int
	var parentBackupDirs string
	var diskFreeRatio float64
	var stopBeforeClusterCreation bool
	var verbose bool
	var pgUpgradeVerbose bool
	var skipVersionCheck bool
	var skipPgUpgradeChecks bool
	var jobs int32
	var ports string
	var mode string
	var useHbaHostnames bool
	var dynamicLibraryPath string
	var dataMigrationSeedDir string

	subInit := &cobra.Command{
		Use:   "initialize",
		Short: "prepare the system for upgrade",
		Long:  InitializeHelp,
		PreRunE: func(cmd *cobra.Command, args []string) error {
			if cmd.Flag("pg-upgrade-verbose").Changed && !cmd.Flag("verbose").Changed {
				return fmt.Errorf("expected --verbose when using --pg-upgrade-verbose")
			}

			isAnyDevModeFlagSet := cmd.Flag("source-gphome").Changed ||
				cmd.Flag("target-gphome").Changed ||
				cmd.Flag("source-master-port").Changed

			// If no required flags are set then return help.
			if !cmd.Flag("file").Changed && !isAnyDevModeFlagSet {
				fmt.Println(InitializeHelp)
				cmd.SilenceErrors = true // silence Quit error message below
				return step.Quit         // exit early and don't call RunE
			}

			// If the file flag is set ensure no other flags are set except
			// optionally verbose, pg-upgrade-verbose, and non-interactive.
			if cmd.Flag("file").Changed {
				var err error
				cmd.Flags().Visit(func(flag *pflag.Flag) {
					if flag.Name != "file" && flag.Name != "verbose" && flag.Name != "pg-upgrade-verbose" && flag.Name != "non-interactive" {
						err = errors.New("The file flag cannot be used with any other flag except verbose and non-interactive.")
					}
				})
				return err
			}

			// In dev mode the file flag should not be set and ensure all dev
			// mode flags are set by marking them required.
			if !cmd.Flag("file").Changed && isAnyDevModeFlagSet {
				devModeFlags := []string{
					"source-gphome",
					"target-gphome",
					"source-master-port",
				}

				for _, f := range devModeFlags {
					cmd.MarkFlagRequired(f) //nolint
				}
			}

			return nil
		},

		RunE: func(cmd *cobra.Command, args []string) (err error) {
			if cmd.Flag("file").Changed {
				configFile, err := os.Open(file)
				if err != nil {
					return err
				}
				defer func() {
					if cErr := configFile.Close(); cErr != nil {
						err = errorlist.Append(err, cErr)
					}
				}()

				flags, err := ParseConfig(configFile)
				if err != nil {
					return xerrors.Errorf("in file %q: %w", file, err)
				}

				err = addFlags(cmd, flags)
				if err != nil {
					return err
				}
			}

			mode, err := parseMode(mode)
			if err != nil {
				return err
			}

			// if diskFreeRatio is not explicitly set, use defaults
			if !cmd.Flag("disk-free-ratio").Changed {
				diskFreeRatio = 0.2
				if mode == idl.Mode_copy {
					diskFreeRatio = 0.6
				}
			}

			if diskFreeRatio < 0.0 || diskFreeRatio > 1.0 {
				// Match Cobra's option-error format.
				return fmt.Errorf(
					`invalid argument %g for "--disk-free-ratio" flag: value must be between 0.0 and 1.0`,
					diskFreeRatio,
				)
			}

			logdir, err := utils.GetLogDir()
			if err != nil {
				return err
			}

			configPath, err := filepath.Abs(file)
			if err != nil {
				return err
			}

			// If we got here, the args are okay and the user doesn't need a usage
			// dump on failure.
			cmd.SilenceUsage = true

			// Create the state directory outside the step framework to ensure
			// we can write to the status file. The step framework assumes valid
			// working state directory.
			err = commanders.CreateStateDir()
			if err != nil {
				return err
			}

			confirmationText := fmt.Sprintf(initializeConfirmationText,
				cases.Title(language.English).String(idl.Step_initialize.String()),
				initializeSubsteps, logdir, configPath,
				sourcePort, sourceGPHome, targetGPHome, mode, diskFreeRatio, jobs, useHbaHostnames, dynamicLibraryPath, ports, hubPort, agentPort)

			recGucTable, err := checkGUCsMeetRecommendedValues(sourceGPHome, sourcePort, jobs)
			if err != nil {
				return err
			}
			defer func() {
				// Print warning banner at the end if any gucs do not meet
				// recommended values. It is deferred so it will still print if
				// initialze fails early, which is often expected if users are
				// fixing checks.
				if recGucTable.NumLines() > 0 {
					fmt.Println("\nWARNING: GUCS DO NOT MATCH RECOMMENDED VALUES")
					recGucTable.Render()
					fmt.Println()
				}
			}()

			st, err := clistep.Begin(idl.Step_initialize, verbose, nonInteractive, confirmationText)
			if err != nil {
				return err
			}

			st.RunConditionally(idl.Substep_verify_gpdb_versions, !skipVersionCheck, func(streams step.OutStreams) error {
				return greenplum.VerifyCompatibleGPDBVersions(sourceGPHome, targetGPHome)
			})

			st.Run(idl.Substep_saving_source_cluster_config, func(streams step.OutStreams) error {
				parsedPorts, err := ParsePorts(ports)
				if err != nil {
					return err
				}

				db, err := connection.Bootstrap(idl.ClusterDestination_source, sourceGPHome, sourcePort)
				if err != nil {
					return err
				}
				defer func() {
					if cErr := db.Close(); cErr != nil {
						err = errorlist.Append(err, cErr)
					}
				}()
				conf, err := config.Create(
					db, hubPort, agentPort,
					filepath.Clean(sourceGPHome),
					filepath.Clean(targetGPHome),
					mode, useHbaHostnames, parsedPorts,
					parentBackupDirs,
				)
				if err != nil {
					return err
				}

				return conf.Write()
			})

			st.Run(idl.Substep_start_hub, func(streams step.OutStreams) error {
				return commanders.StartHub(streams)
			})

			generatedScriptsOutputDir, err := utils.GetDefaultGeneratedDataMigrationScriptsDir()
			if err != nil {
				return err
			}

			st.AlwaysRun(idl.Substep_generate_data_migration_scripts, func(streams step.OutStreams) error {
				if nonInteractive {
					return nil
				}

				return commanders.GenerateDataMigrationScripts(streams, nonInteractive, sourceGPHome, sourcePort, filepath.Clean(dataMigrationSeedDir), generatedScriptsOutputDir, utils.System.DirFS(generatedScriptsOutputDir))
			})

			st.AlwaysRun(idl.Substep_execute_stats_data_migration_scripts, func(streams step.OutStreams) error {
				if nonInteractive {
					return nil
				}

				currentDir := filepath.Join(generatedScriptsOutputDir, "current")
				return commanders.ApplyDataMigrationScripts(streams, nonInteractive, sourceGPHome, sourcePort, logdir, utils.System.DirFS(currentDir), currentDir, idl.Step_stats)
			})

			st.AlwaysRun(idl.Substep_execute_initialize_data_migration_scripts, func(streams step.OutStreams) error {
				if nonInteractive {
					return nil
				}

				currentDir := filepath.Join(filepath.Clean(generatedScriptsOutputDir), "current")
				err = commanders.ApplyDataMigrationScripts(streams, nonInteractive, sourceGPHome, sourcePort,
					logdir, utils.System.DirFS(currentDir), currentDir, idl.Step_initialize)
				if err != nil {
					return err
				}

				prompt := fmt.Sprintf("Continue with gpupgrade %s?  Yy|Nn: ", idl.Step_initialize)
				return clistep.Prompt(utils.StdinReader, prompt)
			})

			var client idl.CliToHubClient
			st.RunHubSubstep(func(streams step.OutStreams) error {
				client, err = connectToHub()
				if err != nil {
					return err
				}

				request := &idl.InitializeRequest{
					DiskFreeRatio:    diskFreeRatio,
					ParentBackupDirs: parentBackupDirs,
				}
				err = commanders.Initialize(client, request, verbose)
				if err != nil {
					return err
				}

				return nil
			})

			var response *idl.InitializeResponse
			st.RunHubSubstep(func(streams step.OutStreams) error {
				if stopBeforeClusterCreation {
					return step.Skip
				}

				request := &idl.InitializeCreateClusterRequest{
					DynamicLibraryPath:  dynamicLibraryPath,
					PgUpgradeVerbose:    pgUpgradeVerbose,
					SkipPgUpgradeChecks: skipPgUpgradeChecks,
				}
				response, err = commanders.InitializeCreateCluster(client, request, verbose)
				if err != nil {
					return err
				}

				return nil
			})

			revertWarning := ""
			if !response.GetHasAllMirrorsAndStandby() && mode == idl.Mode_link {
				revertWarning = revertWarningText
			}

			err = st.Complete(fmt.Sprintf(InitializeCompletedText, revertWarning))
			if err != nil {
				return err
			}

			return nil
		},
	}

	subInit.Flags().BoolVarP(&verbose, "verbose", "v", false, "print the output stream from all substeps")
	subInit.Flags().BoolVar(&pgUpgradeVerbose, "pg-upgrade-verbose", false, "execute pg_upgrade with --verbose")
	subInit.Flags().BoolVar(&skipPgUpgradeChecks, "skip-pg-upgrade-checks", false, "skips pg_upgrade checks")
	subInit.Flags().MarkHidden("skip-pg-upgrade-checks") //nolint
	subInit.Flags().Int32Var(&jobs, "jobs", 4, "number of jobs to run for steps that can run in parallel. Defaults to 4.")
	subInit.Flags().StringVarP(&file, "file", "f", "", "the configuration file to use")
	subInit.Flags().BoolVar(&nonInteractive, "non-interactive", false, "do not prompt for confirmation to proceed")
	subInit.Flags().MarkHidden("non-interactive") //nolint
	subInit.Flags().IntVar(&sourcePort, "source-master-port", 0, "master port for source gpdb cluster")
	subInit.Flags().StringVar(&sourceGPHome, "source-gphome", "", "path for the source Greenplum installation")
	subInit.Flags().StringVar(&targetGPHome, "target-gphome", "", "path for the target Greenplum installation")
	subInit.Flags().StringVar(&mode, "mode", "copy", "performs upgrade in either copy or link mode. Default is copy.")
	subInit.Flags().StringVar(&parentBackupDirs, "parent-backup-dirs", "", "parent directories on each host to internally store the backup of the coordinator data directory and user defined coordinator tablespaces."+
		"Defaults to the parent directory of each primary data directory on each primary host."+
		"To specify a single directory across all hosts set /dir."+
		"To specify different directories for each host use the form \"host1:/dir1,host2:/dir2,host3:/dir3\" where the first host must be the coordinator.")
	subInit.Flags().Float64Var(&diskFreeRatio, "disk-free-ratio", 0.60, "percentage of disk space that must be available (from 0.0 - 1.0)")
	subInit.Flags().BoolVar(&useHbaHostnames, "use-hba-hostnames", false, "use hostnames in pg_hba.conf")
	subInit.Flags().StringVar(&dynamicLibraryPath, "dynamic-library-path", upgrade.DefaultDynamicLibraryPath, "sets the dynamic_library_path GUC to correctly find extensions installed outside their default location. Defaults to '$dynamic_library_path'.")
	subInit.Flags().StringVar(&ports, "temp-port-range", "50432-65535", "set of ports to use when initializing the target cluster")
	subInit.Flags().IntVar(&hubPort, "hub-port", upgrade.DefaultHubPort, "the port gpupgrade hub uses to listen for commands on")
	subInit.Flags().IntVar(&agentPort, "agent-port", upgrade.DefaultAgentPort, "the port gpupgrade agent uses to listen for commands on")
	subInit.Flags().BoolVar(&stopBeforeClusterCreation, "stop-before-cluster-creation", false, "only run up to pre-init")
	subInit.Flags().MarkHidden("stop-before-cluster-creation") //nolint
	subInit.Flags().BoolVar(&skipVersionCheck, "skip-version-check", false, "disable source and target version check")
	subInit.Flags().MarkHidden("skip-version-check") //nolint
	// seed-dir is a hidden flag used for internal testing.
	subInit.Flags().StringVar(&dataMigrationSeedDir, "seed-dir", utils.GetDataMigrationSeedDir(), "path to the seed scripts")
	subInit.Flags().MarkHidden("seed-dir") //nolint

	return addHelpToCommand(subInit, InitializeHelp)
}

func ParsePorts(val string) ([]int, error) {
	var ports []int

	if val == "" {
		return ports, nil
	}

	for _, p := range strings.Split(val, ",") {
		parts := strings.Split(p, "-")
		switch {
		case len(parts) == 2: // this is a range
			low, err := strconv.ParseUint(parts[0], 10, 16)
			if err != nil {
				return nil, xerrors.Errorf("failed to parse port range %s", p)
			}

			high, err := strconv.ParseUint(parts[1], 10, 16)
			if err != nil {
				return nil, xerrors.Errorf("failed to parse port range %s", p)
			}

			if low > high {
				return nil, xerrors.Errorf("invalid port range %s", p)
			}

			for i := low; i <= high; i++ {
				ports = append(ports, int(i))
			}

		default: // single port
			port, err := strconv.ParseUint(p, 10, 16)
			if err != nil {
				return nil, xerrors.Errorf("failed to parse port %s", p)
			}

			ports = append(ports, int(port))
		}
	}

	return ports, nil
}

// parseMode parses the mode flag returning an error if it is not a valid mode choice.
func parseMode(input string) (idl.Mode, error) {
	input = strings.ToLower(strings.TrimSpace(input))
	if modeInt, ok := idl.Mode_value[input]; ok {
		return idl.Mode(modeInt), nil
	}

	var choices []string
	for _, mode := range idl.Mode_name {
		if mode != idl.Mode_unknown_mode.String() {
			choices = append(choices, mode)
		}
	}

	return idl.Mode_unknown_mode, fmt.Errorf("Invalid input %q. Please specify either %s.", input, strings.Join(choices, ", "))
}

func addFlags(cmd *cobra.Command, flags map[string]string) error {
	for name, value := range flags {
		flag := cmd.Flag(name)
		if flag == nil {
			var names []string
			cmd.Flags().VisitAll(func(flag *pflag.Flag) {
				names = append(names, flag.Name)
			})
			return xerrors.Errorf("The configuration parameter %q was not found in the list of supported parameters: %s.", name, strings.Join(names, ", "))
		}

		err := flag.Value.Set(value)
		if err != nil {
			return xerrors.Errorf("set %q to %q: %w", name, value, err)
		}

		cmd.Flag(name).Changed = true
	}

	return nil
}

type gucRecommendation struct {
	Name        string
	Operator    string
	Recommended string
}

// calculating recommended guc settings
// returns a table of recommended gucs to be rendered at the end of initialize
func checkGUCsMeetRecommendedValues(gphome string, port int, jobs int32) (*tablewriter.Table, error) {
	db, err := connection.Bootstrap(idl.ClusterDestination_source, gphome, port)
	defer func() {
		if cErr := db.Close(); cErr != nil {
			err = errorlist.Append(err, cErr)
		}
	}()
	if err != nil {
		return nil, err
	}

	memTotalKB, swapTotalKB, err := ReadMemoryStats()
	if err != nil {
		return nil, err
	}

	// max_statement_mem = (seghost_physical_memory) / (average_number_concurrent_queries)
	recMaxStatementMemKB := float64(uint64(memTotalKB) / uint64(jobs))

	// gp_vmem = ((SWAP + RAM) – (7.5GB + 0.05 * RAM)) / [ 1.7 | 1.17 ]
	var recGpVmemKB float64
	if memTotalKB >= (128 * (1 << 20)) {
		// If the total system memory is equal to or greater than 256 GB, use this formula
		recGpVmemKB = float64(float64(swapTotalKB+memTotalKB)-(float64(7.5*(1<<20))+0.05*float64(memTotalKB))) / float64(1.17)
	} else {
		recGpVmemKB = float64(float64(swapTotalKB+memTotalKB)-(float64(7.5*(1<<20))+0.05*float64(memTotalKB))) / float64(1.7)
	}

	// acting_primary_segments = segments per host + number of possible active mirrors
	maxActingPrimarySegments, err := getMaxActingPrimarySegments(db)
	if err != nil {
		return nil, err
	}

	// statement_mem = ( <gp_vmem_protect_limit>GB * .9 ) / <max_expected_concurrent_queries>
	recStatementMemKB := (recGpVmemKB * .9) / float64(jobs)

	// gp_vmem_protect_limit = <gp_vmem> / <acting_primary_segments>
	recGpVmemProtectLimitKB := recGpVmemKB / float64(maxActingPrimarySegments)

	recStatementMemGB := fmt.Sprintf("%dGB", convertKBtoGB(recStatementMemKB))
	recMaxStatementMemGB := fmt.Sprintf("%dGB", convertKBtoGB(recMaxStatementMemKB))
	recGpVmemProtectLimitGB := fmt.Sprintf("%dGB", convertKBtoGB(recGpVmemProtectLimitKB))
	gucList := []gucRecommendation{
		{"gp_vmem_protect_limit", ">=", recGpVmemProtectLimitGB},
		{"max_statement_mem", ">=", recMaxStatementMemGB},
		{"statement_mem", ">=", recStatementMemGB},
		{"max_locks_per_transaction", ">=", "512"},
	}

	table := tablewriter.NewWriter(os.Stdout)
	var warnings []string
	for _, guc := range gucList {
		line, entry, err := checkGUC(db, guc)
		if err != nil {
			return nil, err
		}
		if line != "" {
			warnings = append(warnings, line)
			table.Append(entry)
		}
	}

	if len(warnings) > 0 {
		// output to log
		log.SetPrefix(logger.Prefix("WARN"))
		fmt.Println()
		for _, line := range warnings {
			// fmt.Printf("WARNING: %s\n", line) // print warning to screen in case of premature initialize fail and return
			log.Println(line)
		}
		log.SetPrefix(logger.Prefix("INFO"))

		// set table render settings for UI
		table.SetHeader([]string{"GUC", "Current", "Recommended"})
		table.SetAlignment(tablewriter.ALIGN_LEFT)
	}

	return table, nil
}

// Returns
// 1. line to be logged
// 2. table entry to be rendered
// 3. err
func checkGUC(db *sql.DB, guc gucRecommendation) (string, []string, error) {
	query := fmt.Sprintf("SHOW %s", guc.Name)
	rows, err := db.Query(query)
	if err != nil {
		return "", nil, err
	}
	defer rows.Close()

	if !rows.Next() {
		return "", nil, fmt.Errorf("No GUC value returned for %s", guc)
	}
	var actual string
	if err := rows.Scan(&actual); err != nil {
		return "", nil, err
	}

	if err := rows.Err(); err != nil {
		return "", nil, err
	}

	var logLine string
	var tableEntry []string
	switch guc.Operator {
	case ">=":
		if !(actual >= guc.Recommended) {
			logLine = fmt.Sprintf("GUC %s currently set at %s. Recommend >= %s", guc.Name, actual, guc.Recommended)
			tableEntry = []string{guc.Name, actual, fmt.Sprintf(">= %s", guc.Recommended)}
		}
	}

	return logLine, tableEntry, nil
}

// max_acting_primary_segments
func getMaxActingPrimarySegments(db *sql.DB) (int, error) {
	query := fmt.Sprintf("SELECT hostname, count(content) AS acting_primary_segments FROM gp_segment_configuration GROUP BY hostname ORDER BY 2;")
	rows, err := db.Query(query)
	if err != nil {
		return -1, fmt.Errorf("acting primaries query fail: %s", err)
	}
	defer rows.Close()

	if !rows.Next() {
		return -1, fmt.Errorf("acting primaries no rows")
	}

	var actingPrimaries int
	var hostname string
	if err := rows.Scan(&hostname, &actingPrimaries); err != nil {
		return -1, fmt.Errorf("acting primaries scan fail: %s", err)
	}

	return actingPrimaries, nil
}

// returns total memory and swap in kB
func ReadMemoryStats() (memTotal uint64, swapTotal uint64, parseErr error) {
	file, err := os.Open("/proc/meminfo")
	if err != nil {
		panic(err)
	}
	defer file.Close()
	bufio.NewScanner(file)
	scanner := bufio.NewScanner(file)
	for scanner.Scan() {
		key, value, err := parseMemInfoLine(scanner.Text())
		if err != nil {
			parseErr = err
			return
		}
		switch key {
		case "MemTotal":
			memTotal = value
		case "SwapTotal":
			swapTotal = value
		}
	}
	return
}

func parseMemInfoLine(raw string) (string, uint64, error) {
	if string(raw[len(raw)-1]) == "0" {
		return "", 0, nil
	}
	text := strings.ReplaceAll(raw[:len(raw)-2], " ", "")
	keyValue := strings.Split(text, ":")
	value, err := strconv.ParseUint(keyValue[1], 10, 64)
	if err != nil {
		return "", 0, fmt.Errorf("failed to read value from key '%s' in /proc/meminfo", keyValue[1])
	}
	return keyValue[0], value, nil
}

func convertKBtoGB(value float64) uint {
	return uint(math.Round(float64(value) / (1 << 20)))
}
