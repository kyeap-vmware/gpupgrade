// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package commands

/*
 *  This file generates the command-line cli that is the heart of gpupgrade.  It uses Cobra to generate
 *    the cli based on commands and sub-commands. The below in this comment block shows a notional example
 *    of how this looks to give you an idea of what the command structure looks like at the cli.  It is NOT necessarily
 *    up-to-date but is a useful as an orientation to what is going on here.
 *
 * example> gpupgrade
 * 	   2018/09/28 16:09:39 Please specify one command of: check, config, prepare, status, upgrade, or version
 *
 * example> gpupgrade check
 *      collects information and validates the target Greenplum installation can be upgraded
 *
 *      Usage:
 * 		gpupgrade check [command]
 *
 * 		Available Commands:
 * 			config       gather cluster configuration
 * 			disk-space   check that disk space usage is less than 80% on all segments
 * 			object-count count database objects and numeric objects
 * 			version      validate current version is upgradable
 *
 * 		Flags:
 * 			-h, --help   help for check
 *
 * 		Use "gpupgrade check [command] --help" for more information about a command.
 */

import (
	"context"
	"errors"
	"fmt"
	"log"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/spf13/cobra"
	"github.com/spf13/pflag"
	"golang.org/x/xerrors"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"github.com/greenplum-db/gpupgrade/cli/commanders"
	"github.com/greenplum-db/gpupgrade/config"
	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/step"
	"github.com/greenplum-db/gpupgrade/upgrade"
	"github.com/greenplum-db/gpupgrade/utils"
)

func BuildRootCommand() *cobra.Command {
	var shouldPrintVersion bool
	var format string

	root := &cobra.Command{
		Use: "gpupgrade",
		RunE: func(cmd *cobra.Command, args []string) error {
			if shouldPrintVersion {
				printVersion(format)
				return nil
			}

			fmt.Print(GlobalHelp)
			return nil
		},
	}

	root.Flags().BoolVarP(&shouldPrintVersion, "version", "V", false, "prints version")
	root.Flags().StringVar(&format, "format", "", `specify the output format as either "multiline", "oneline", or "json". Default is multiline.`)

	root.AddCommand(configCmd)
	root.AddCommand(version())
	root.AddCommand(dataMigrationGenerate())
	root.AddCommand(dataMigrationApply())
	root.AddCommand(check())
	root.AddCommand(initialize())
	root.AddCommand(execute())
	root.AddCommand(finalize())
	root.AddCommand(revert())
	root.AddCommand(restartServices)
	root.AddCommand(killServices)
	root.AddCommand(Agent())
	root.AddCommand(Hub())

	subConfigShow := createConfigShowSubcommand()
	configCmd.AddCommand(subConfigShow)

	return addHelpToCommand(root, GlobalHelp)
}

//////////////////////////// Commands //////////////////////////////////////////

var configCmd = &cobra.Command{
	Use:   "config",
	Short: "subcommands to set parameters for subsequent gpupgrade commands",
	Long:  "subcommands to set parameters for subsequent gpupgrade commands",
}

func createConfigShowSubcommand() *cobra.Command {
	cmd := &cobra.Command{
		Use:   "show",
		Short: "show configuration settings",
		Long:  "show configuration settings",
		RunE: func(cmd *cobra.Command, args []string) error {
			client, err := connectToHub()
			if err != nil {
				return err
			}

			// Build a list of GetConfigRequests, one for each flag. If no flags
			// are passed, assume we want to retrieve all of them.
			var requests []*idl.GetConfigRequest
			getRequest := func(flag *pflag.Flag) {
				if flag.Name != "help" && flag.Name != "?" {
					requests = append(requests, &idl.GetConfigRequest{
						Name: flag.Name,
					})
				}
			}

			if cmd.Flags().NFlag() > 0 {
				cmd.Flags().Visit(getRequest)
			} else {
				cmd.Flags().VisitAll(getRequest)
			}

			// Make the requests and print every response.
			for _, request := range requests {
				resp, err := client.GetConfig(context.Background(), request)
				if err != nil {
					return err
				}

				if cmd.Flags().NFlag() == 1 {
					// Don't prefix with the setting name if the user only asked for one.
					fmt.Println(resp.Value)
				} else {
					fmt.Printf("%s: %s\n", request.Name, resp.Value)
				}
			}

			return nil
		},
	}

	cmd.Flags().Bool("upgrade-id", false, "show upgrade identifier")
	cmd.Flags().Bool("source-gphome", false, "show path for the source Greenplum installation")
	cmd.Flags().Bool("target-gphome", false, "show path for the target Greenplum installation")
	cmd.Flags().Bool("target-datadir", false, "show temporary data directory for target gpdb cluster")
	cmd.Flags().Bool("target-port", false, "show temporary master port for target cluster")

	return addHelpToCommand(cmd, ConfigHelp)
}

func version() *cobra.Command {
	var format string

	cmd := &cobra.Command{
		Use:   "version",
		Short: "Version of gpupgrade",
		Long:  `Version of gpupgrade`,
		Run: func(cmd *cobra.Command, args []string) {
			printVersion(format)
		},
	}

	cmd.Flags().StringVar(&format, "format", "", `specify the output format as either "multiline", "oneline", or "json". Default is multiline.`)

	return cmd
}

var restartServices = &cobra.Command{
	Use:   "restart-services",
	Short: "restarts hub/agents that are not currently running",
	Long:  "restarts hub/agents that are not currently running",
	RunE: func(cmd *cobra.Command, args []string) error {
		err := commanders.StartHub(step.StdStreams)
		if err != nil && !errors.Is(err, step.Skip) {
			return err
		}

		if !errors.Is(err, step.Skip) {
			fmt.Println("Restarted hub")
		}

		client, err := connectToHub()
		if err != nil {
			return err
		}

		reply, err := client.RestartAgents(context.Background(), &idl.RestartAgentsRequest{})
		if err != nil {
			return xerrors.Errorf("restarting agents: %w", err)
		}

		fmt.Printf("Restarted agents on: %s\n", strings.Join(reply.GetAgentHosts(), ", "))
		return nil
	},
}

var killServices = &cobra.Command{
	Use:   "kill-services",
	Short: "Abruptly stops the hub and agents that are currently running.",
	Long: "Abruptly stops the hub and agents that are currently running.\n" +
		"Return if no hub is running, which may leave spurious agents running.",
	RunE: func(cmd *cobra.Command, args []string) error {
		running, err := commanders.IsHubRunning()
		if err != nil {
			return xerrors.Errorf("is hub running: %w", err)
		}

		if !running {
			// FIXME: Returning early if the hub is not running, means that we
			// cannot kill spurious agents. We cannot simply start the hub in
			// order to kill spurious agents since this requires initialize to
			// have been run and the source cluster config to exist. The main
			// use case for kill-services is at the start of acceptance testing
			// where we do not want to make any assumption about the state of
			// the cluster or environment.
			return nil
		}

		return stopHubAndAgents()
	},
}

func stopHubAndAgents() error {
	port, err := hubPort()
	if err != nil {
		return xerrors.Errorf("hub port: %w", err)
	}

	client, err := connectToHubOnPort(port)
	if err != nil {
		return err
	}

	_, err = client.StopServices(context.Background(), &idl.StopServicesRequest{})
	if idl.ServerAlreadyStopped(err) {
		return nil
	}

	if err != nil {
		return err
	}

	return nil
}

//////////////////////////// Helpers ///////////////////////////////////////////

// calls connectToHubOnPort() using the port defined in the configuration file
func connectToHub() (idl.CliToHubClient, error) {
	port, err := hubPort()
	if err != nil {
		return nil, xerrors.Errorf("hub port: %w", err)
	}

	return connectToHubOnPort(port)
}

// connectToHubOnPort() performs a blocking connection to the hub based on the
// passed in port, and returns a CliToHubClient which wraps the resulting gRPC channel.
// Any errors result in a call to os.Exit(1).
func connectToHubOnPort(port int) (idl.CliToHubClient, error) {
	// Set up our timeout.
	ctx, cancel := context.WithTimeout(context.Background(), connTimeout())
	defer cancel()

	// Attempt a connection.
	address := "localhost:" + strconv.Itoa(port)
	conn, err := grpc.DialContext(ctx, address, grpc.WithTransportCredentials(insecure.NewCredentials()), grpc.WithBlock())
	if err != nil {
		err = xerrors.Errorf("connecting to hub on port %d: %w", port, err)
		if ctx.Err() == context.DeadlineExceeded {
			nextAction := `Try restarting the hub with "gpupgrade restart-services".`
			return nil, utils.NewNextActionErr(err, nextAction)
		}
		return nil, err
	}

	return idl.NewCliToHubClient(conn), nil
}

// connTimeout retrieves the GPUPGRADE_CONNECTION_TIMEOUT environment variable,
// interprets it as a (possibly fractional) number of seconds, and converts it
// into a Duration. The default is one second if the envvar is unset or
// unreadable.
//
// TODO: should we make this a global --option instead?
func connTimeout() time.Duration {
	const defaultDuration = time.Second

	seconds, ok := os.LookupEnv("GPUPGRADE_CONNECTION_TIMEOUT")
	if !ok {
		return defaultDuration
	}

	duration, err := strconv.ParseFloat(seconds, 64)
	if err != nil {
		log.Printf(`GPUPGRADE_CONNECTION_TIMEOUT of "%s" is invalid (%s); using default of one second`,
			seconds, err)
		return defaultDuration
	}

	return time.Duration(duration * float64(time.Second))
}

// hubPort reads the gpupgrade persisted configuration for the current
// port. If the configuration does not exist the default port is returned.
// NOTE: This overloads the hub's persisted configuration with that of the
// CLI when ideally these would be separate.
func hubPort() (int, error) {
	conf, err := config.Read()
	var pathError *os.PathError
	if errors.As(err, &pathError) {
		return upgrade.DefaultHubPort, nil
	}

	if err != nil {
		return -1, xerrors.Errorf("read config: %w", err)
	}

	return conf.HubPort, nil
}
