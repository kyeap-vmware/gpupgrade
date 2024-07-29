// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package gpupgrade_test

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"testing"

	"github.com/greenplum-db/gpupgrade/cli/commanders"
	"github.com/greenplum-db/gpupgrade/config"
	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/idl"
	"github.com/greenplum-db/gpupgrade/step"
	"github.com/greenplum-db/gpupgrade/substeps"
	"github.com/greenplum-db/gpupgrade/testutils"
	"github.com/greenplum-db/gpupgrade/testutils/acceptance"
	"github.com/greenplum-db/gpupgrade/upgrade"
	"github.com/greenplum-db/gpupgrade/utils"
)

func TestInitialize(t *testing.T) {
	stateDir := testutils.GetTempDir(t, "")
	defer testutils.MustRemoveAll(t, stateDir)

	resetEnv := testutils.SetEnv(t, "GPUPGRADE_HOME", stateDir)
	defer resetEnv()

	t.Run("initialize accepts a port range", func(t *testing.T) {
		expectedPortRange := "30432,30434,30435,30436,30433,30437,30438,30439" // primaries,standby,mirrors

		cmd := exec.Command("gpupgrade", "initialize",
			"--non-interactive", "--verbose",
			"--mode", idl.Mode_copy.String(),
			"--source-gphome", acceptance.GPHOME_SOURCE,
			"--target-gphome", acceptance.GPHOME_TARGET,
			"--source-master-port", acceptance.PGPORT,
			"--temp-port-range", expectedPortRange,
			"--disk-free-ratio", "0")
		output, err := cmd.CombinedOutput()
		defer acceptance.Revert(t)
		if err != nil {
			t.Fatalf("unexpected err: %#v stderr %q", err, output)
		}

		conf, err := config.Read()
		if err != nil {
			t.Fatal(err)
		}

		var ports []string
		for _, seg := range conf.Intermediate.Primaries {
			ports = append(ports, strconv.Itoa(seg.Port))
		}

		for _, seg := range conf.Intermediate.Mirrors {
			ports = append(ports, strconv.Itoa(seg.Port))
		}

		expectedPorts := strings.Split(expectedPortRange, ",")

		sort.Strings(ports)
		sort.Strings(expectedPorts)

		if !reflect.DeepEqual(ports, expectedPorts) {
			t.Errorf("got %v want %v", ports, expectedPorts)
		}
	})

	t.Run("fails when temp-port-range overlaps with source cluster ports", func(t *testing.T) {
		cmd := exec.Command("gpupgrade", "initialize",
			"--non-interactive", "--verbose",
			"--mode", idl.Mode_copy.String(),
			"--source-gphome", acceptance.GPHOME_SOURCE,
			"--target-gphome", acceptance.GPHOME_TARGET,
			"--source-master-port", acceptance.PGPORT,
			"--temp-port-range", acceptance.PGPORT+"-"+strconv.Itoa(testutils.MustConvertStringToInt(t, acceptance.PGPORT)+20),
			"--disk-free-ratio", "0")
		output, err := cmd.CombinedOutput()
		if err == nil {
			t.Errorf("expected nil got error %v", err)
		}

		hostname, err := os.Hostname()
		if err != nil {
			t.Fatal(err)
		}

		match := fmt.Sprintf("Error: substep %q: "+
			"temp_port_range contains port \\d+ which overlaps with the source cluster ports on host %s. "+
			"Specify a non-overlapping temp_port_range.", idl.Substep_saving_source_cluster_config, hostname)
		expected := regexp.MustCompile(match)
		if !expected.Match(output) {
			t.Fatalf("expected %s to contain %s", output, expected)
		}
	})

	// TODO: Move to integration/agent_test.go
	t.Run("start agents fails if a process is connected on the same TCP port", func(t *testing.T) {
		stopListening := testutils.MustListenOnPort(t, upgrade.DefaultAgentPort)
		defer stopListening()

		cmd := exec.Command("gpupgrade", "initialize",
			"--non-interactive", "--verbose",
			"--source-gphome", acceptance.GPHOME_SOURCE,
			"--target-gphome", acceptance.GPHOME_TARGET,
			"--source-master-port", acceptance.PGPORT,
			"--temp-port-range", acceptance.TARGET_PGPORT+"-6040",
			"--stop-before-cluster-creation",
			"--disk-free-ratio", "0")
		output, err := cmd.CombinedOutput()
		defer acceptance.Revert(t)
		if err == nil {
			t.Errorf("expected nil got error %v", err)
		}

		expected := fmt.Sprintf("substep %q: exit status 1: Error: listen on port %d: listen tcp :%d: bind: address already in use", idl.Substep_start_agents, upgrade.DefaultAgentPort, upgrade.DefaultAgentPort)
		if !strings.Contains(string(output), expected) {
			t.Fatalf("expected %q to contain %q", output, expected)
		}
	})

	t.Run("the check upgrade substep always runs", func(t *testing.T) {
		// run initialize
		acceptance.Initialize(t, idl.Mode_copy)
		defer acceptance.Revert(t)

		source := acceptance.GetSourceCluster(t)

		// create a non-upgradeable object to assert pg_upgrade --check is always run
		if source.Version.Major == 5 {
			testutils.MustExecuteSQL(t, source.Connection(), `SELECT lo_create(1);`)
			defer testutils.MustExecuteSQL(t, source.Connection(), `SELECT lo_unlink(loid) FROM pg_largeobject;`)
		} else if source.Version.Major == 6 {
			testutils.MustExecuteSQL(t, source.Connection(), `
			CREATE TABLE public.table_using_system_defined_type (pg_type_column pg_type);`)
			defer testutils.MustExecuteSQL(t, source.Connection(), `DROP TABLE public.table_using_system_defined_type;`)
		} else {
			t.Fatalf("unexpected major version %d", source.Version.Major)
		}

		// re-run initialize and check that pg_upgrade --check ran
		cmd := exec.Command("gpupgrade", "initialize",
			"--non-interactive", "--verbose",
			"--mode", idl.Mode_copy.String(),
			"--source-gphome", acceptance.GPHOME_SOURCE,
			"--target-gphome", acceptance.GPHOME_TARGET,
			"--source-master-port", acceptance.PGPORT,
			"--temp-port-range", acceptance.TARGET_PGPORT+"-6040",
			"--disk-free-ratio", "0")
		output, err := cmd.CombinedOutput()
		if err == nil {
			t.Errorf("expected nil got error %v", err)
		}

		substepOutputText := substeps.SubstepDescriptions[idl.Substep_check_upgrade].OutputText
		substepText := commanders.Format(substepOutputText, idl.Status_failed)
		if !strings.Contains(string(output), substepText) {
			t.Fatalf("expected execute to fail with %q got %q", substepText, string(output))
		}
	})

	t.Run("the source cluster is running at the end of initialize", func(t *testing.T) {
		acceptance.Initialize(t, idl.Mode_copy)
		defer acceptance.Revert(t)

		testutils.VerifyClusterIsRunning(t, acceptance.GetSourceCluster(t))
	})

	t.Run("gpupgrade initialize runs pg_upgrade --check on coordinator and primaries", func(t *testing.T) {
		acceptance.Initialize(t, idl.Mode_copy)
		defer acceptance.Revert(t)

		logs := []string{
			testutils.MustGetLog(t, "hub"),
			acceptance.MustGetPgUpgradeLog(t, -1),
			acceptance.MustGetPgUpgradeLog(t, 0),
			acceptance.MustGetPgUpgradeLog(t, 1),
			acceptance.MustGetPgUpgradeLog(t, 2),
		}

		for _, log := range logs {
			contents := testutils.MustReadFile(t, log)
			expected := "Clusters are compatible"
			if !strings.Contains(contents, expected) {
				t.Errorf("expected %q to contain %q", contents, expected)
			}
		}
	})

	t.Run("upgrade maintains separate DBID for each segment and initialize runs gpinitsystem based on the source cluster", func(t *testing.T) {
		source := acceptance.GetSourceCluster(t)

		acceptance.Initialize(t, idl.Mode_copy)
		defer acceptance.Revert(t)

		acceptance.Execute(t)

		conf, err := config.Read()
		if err != nil {
			t.Fatal(err)
		}

		intermediate := acceptance.GetIntermediateCluster(t)
		if len(source.Primaries) != len(intermediate.Primaries) {
			t.Fatalf("got %d want %d", len(source.Primaries), len(intermediate.Primaries))
		}

		segPrefix, err := greenplum.GetCoordinatorSegPrefix(source.CoordinatorDataDir())
		if err != nil {
			t.Fatal(err)
		}

		sourcePrimaries := source.SelectSegments(func(segConfig *greenplum.SegConfig) bool {
			return segConfig.IsPrimary() || segConfig.IsCoordinator()
		})

		sort.Sort(sourcePrimaries)

		expectedPort := 6020
		for _, sourcePrimary := range sourcePrimaries {
			intermediatePrimary := intermediate.Primaries[sourcePrimary.ContentID]

			if _, ok := intermediate.Primaries[sourcePrimary.ContentID]; !ok {
				t.Fatalf("source cluster primary segment with content id %d does not exist in the intermediate cluster", sourcePrimary.ContentID)
			}

			if sourcePrimary.DbID != intermediatePrimary.DbID {
				t.Errorf("got %d want %d", sourcePrimary.DbID, intermediatePrimary.DbID)
			}

			expectedDataDir := upgrade.TempDataDir(sourcePrimary.DataDir, segPrefix, conf.UpgradeID)
			if intermediatePrimary.DataDir != expectedDataDir {
				t.Errorf("got %q want %q", intermediatePrimary.DataDir, expectedDataDir)
			}

			if intermediatePrimary.Port != expectedPort {
				t.Errorf("got %d want %d", intermediatePrimary.Port, expectedPort)
			}

			expectedPort++
			if expectedPort == 6021 {
				// skip the standby port as the standby is created during finalize
				expectedPort++
			}
		}
	})

	t.Run("init target cluster is idempotent", func(t *testing.T) {
		acceptance.Initialize(t, idl.Mode_copy)
		defer acceptance.Revert(t)

		conf, err := config.Read()
		if err != nil {
			t.Fatal(err)
		}

		// simulate a gpinitsystem cluster failure by removing a segment's data directory
		seg := conf.Intermediate.Primaries[1]
		testutils.MustRemoveAll(t, seg.DataDir)

		// simulate a gpinitsystem cluster failure by marking that substep as failed
		replaced := acceptance.Jq(t, filepath.Join(utils.GetStateDir(), step.SubstepsFileName), `.initialize.init_target_cluster = "failed"`)
		testutils.MustWriteToFile(t, filepath.Join(utils.GetStateDir(), step.SubstepsFileName), replaced)

		// re-run initialize
		acceptance.Initialize(t, idl.Mode_copy)
	})

	t.Run("all substeps can be re-run after completion", func(t *testing.T) {
		acceptance.Initialize(t, idl.Mode_copy)
		defer acceptance.Revert(t)

		// As a hacky way of testing substep idempotence mark all initialize substeps as failed and re-run.
		replaced := acceptance.Jq(t, filepath.Join(utils.GetStateDir(), step.SubstepsFileName), `(.initialize | values[]) |= "failed"`)
		testutils.MustWriteToFile(t, filepath.Join(utils.GetStateDir(), step.SubstepsFileName), replaced)

		acceptance.Initialize(t, idl.Mode_copy)
	})
}
