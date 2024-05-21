// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package greenplum

import (
	"database/sql"
	"fmt"
	"log"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/blang/semver/v4"
	"golang.org/x/xerrors"

	"github.com/greenplum-db/gpupgrade/testutils/exectest"
)

var versionCommand = exec.Command

// XXX: for internal testing only
func SetVersionCommand(command exectest.Command) {
	versionCommand = command
}

// XXX: for internal testing only
func ResetVersionCommand() {
	versionCommand = exec.Command
}

func VersionStringFromDB(db *sql.DB) (semver.Version, error) {
	var rawVersion string
	err := db.QueryRow("SELECT version()").Scan(&rawVersion)
	if err != nil {
		return semver.Version{}, xerrors.Errorf("querying version: %w", err)
	}

	parts := strings.SplitN(strings.TrimSpace(string(rawVersion)), "(Greenplum Database ", 2)
	if len(parts) != 2 {
		return semver.Version{}, xerrors.Errorf(`Greenplum version %q is not of the form "PostgreSQL #.#.# (Greenplum Database #.#.#)"`, rawVersion)
	}
	parts = strings.Split(parts[1], ")")

	pattern := regexp.MustCompile(`\d+\.\d+\.\d+`)
	matches := pattern.FindStringSubmatch(parts[0])
	if len(matches) < 1 {
		return semver.Version{}, xerrors.Errorf("parsing Greenplum version %q: %w", rawVersion, err)
	}
	version, err := semver.Parse(matches[0])
	if err != nil {
		return semver.Version{}, xerrors.Errorf("parsing Greenplum version %q: %w", rawVersion, err)
	}

	return version, nil
}

func VersionStringFromGPHome(gphome string) (semver.Version, error) {
	cmd := versionCommand(filepath.Join(gphome, "bin", "postgres"), "--gp-version")
	cmd.Env = []string{}

	log.Printf("Executing: %q", cmd.String())
	rawVersion, err := cmd.CombinedOutput()
	if err != nil {
		return semver.Version{}, fmt.Errorf("%q failed with %q: %w", cmd.String(), string(rawVersion), err)
	}

	parts := strings.SplitN(strings.TrimSpace(string(rawVersion)), "postgres (Greenplum Database) ", 2)
	if len(parts) != 2 {
		return semver.Version{}, xerrors.Errorf(`Greenplum version %q is not of the form "postgres (Greenplum Database) #.#.#"`, rawVersion)
	}
	pattern := regexp.MustCompile(`\d+\.\d+\.\d+`)
	matches := pattern.FindStringSubmatch(parts[1])
	if len(matches) < 1 {
		return semver.Version{}, xerrors.Errorf("parsing Greenplum version %q: %w", rawVersion, err)
	}
	version, err := semver.Parse(matches[0])
	if err != nil {
		return semver.Version{}, xerrors.Errorf("parsing Greenplum version %q: %w", rawVersion, err)
	}

	return version, nil
}

func Version(from any) (semver.Version, error) {
	var version semver.Version
	var err error
	switch v := from.(type) {
	case *sql.DB:
		version, err = VersionStringFromDB(v)
	case string:
		version, err =  VersionStringFromGPHome(v)
	default:
		return semver.Version{}, xerrors.Errorf("unexpected type %T", from)
	}

	if err != nil {
		return semver.Version{}, err
	}

	return version, nil
}
