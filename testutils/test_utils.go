// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package testutils

import (
	"log"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"testing"

	"github.com/blang/semver/v4"

	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/upgrade"
	"github.com/greenplum-db/gpupgrade/utils"
	"github.com/greenplum-db/gpupgrade/utils/logger"
)

// FailingWriter is an io.Writer for which all calls to Write() return an error.
type FailingWriter struct {
	Err error
}

func (f *FailingWriter) Write(_ []byte) (int, error) {
	return 0, f.Err
}

// TODO remove in favor of MustCreateCluster
func CreateMultinodeSampleCluster(baseDir string) *greenplum.Cluster {
	return &greenplum.Cluster{
		Primaries: map[int]greenplum.SegConfig{
			-1: {ContentID: -1, DbID: 1, Port: 15432, Hostname: "localhost", DataDir: baseDir + "/seg-1", Role: greenplum.PrimaryRole},
			0:  {ContentID: 0, DbID: 2, Port: 25432, Hostname: "host1", DataDir: baseDir + "/seg1", Role: greenplum.PrimaryRole},
			1:  {ContentID: 1, DbID: 3, Port: 25433, Hostname: "host2", DataDir: baseDir + "/seg2", Role: greenplum.PrimaryRole},
		},
	}
}

// TODO remove in favor of MustCreateCluster
func CreateMultinodeSampleClusterPair(baseDir string) (*greenplum.Cluster, *greenplum.Cluster) {
	gpdbVersion := semver.MustParse("6.0.0")

	sourceCluster := CreateMultinodeSampleCluster(baseDir)
	sourceCluster.GPHome = "/usr/local/source"
	sourceCluster.Version = gpdbVersion

	targetCluster := CreateMultinodeSampleCluster(baseDir)
	targetCluster.GPHome = "/usr/local/target"
	targetCluster.Version = gpdbVersion

	return sourceCluster, targetCluster
}

func CreateTablespaces() greenplum.Tablespaces {
	return greenplum.Tablespaces{
		1: {
			16384: {
				Location:    "/tmp/user_ts/m/qddir/16384",
				UserDefined: true,
			},
			1663: {
				Location:    "/tmp/m/qddir/base",
				UserDefined: false,
			},
		},
		2: {
			16384: {
				Location:    "/tmp/user_ts/m/standby/16384",
				UserDefined: true,
			},
			1663: {
				Location:    "/tmp/m/standby/base",
				UserDefined: false,
			},
		},
		3: {
			16384: {
				Location:    "/tmp/user_ts/p1/16384",
				UserDefined: true,
			},
			1663: {
				Location:    "/tmp/p1/base",
				UserDefined: false,
			},
		},
		4: {
			16384: {
				Location:    "/tmp/user_ts/m1/16384",
				UserDefined: true,
			},
			1663: {
				Location:    "/tmp/m1/base",
				UserDefined: false,
			},
		},
		5: {
			16384: {
				Location:    "/tmp/user_ts/p2/16384",
				UserDefined: true,
			},
			1663: {
				Location:    "/tmp/p2/base",
				UserDefined: false,
			},
		},
		6: {
			16384: {
				Location:    "/tmp/user_ts/m2/16384",
				UserDefined: true,
			},
			1663: {
				Location:    "/tmp/m2/base",
				UserDefined: false,
			},
		},
	}
}

func MustGetPort(t *testing.T) int {
	t.Helper()

	listener, err := net.Listen("tcp", ":0")
	if err != nil {
		t.Fatal("failed to listen on tcp:0")
	}
	defer func() {
		err = listener.Close()
		if err != nil {
			t.Fatal("failed to close listener")
		}
	}()

	port := listener.Addr().(*net.TCPAddr).Port
	t.Logf("found available port %d", port)
	return port
}

func GetTempDir(t *testing.T, prefix string) string {
	t.Helper()

	dir, err := os.MkdirTemp("", prefix)
	if err != nil {
		t.Fatalf("creating temporary directory: %+v", err)
	}

	return dir
}

func MustRemoveAll(t *testing.T, dir string) {
	t.Helper()

	err := os.RemoveAll(dir)
	if err != nil {
		t.Fatalf("removing temp dir %q: %+v", dir, err)
	}
}

func MustCreateDir(t *testing.T, path string) {
	t.Helper()

	if err := os.MkdirAll(path, 0700); err != nil {
		t.Fatalf("MkdirAll %q: %+v", path, err)
	}
}

// MustCreateDataDirs returns a temporary source and target data directory that
// looks like a postgres directory. The last argument returned is a cleanup
// function that can be used in a defer.
func MustCreateDataDirs(t *testing.T) (string, string, func(*testing.T)) {
	t.Helper()

	source := GetTempDir(t, "source")
	target := GetTempDir(t, "target")

	for _, dir := range []string{source, target} {
		for _, f := range upgrade.PostgresFiles {
			path := filepath.Join(dir, f)
			err := os.WriteFile(path, []byte(""), 0600)
			if err != nil {
				t.Fatalf("failed creating postgres file %q: %+v", path, err)
			}
		}
	}

	return source, target, func(t *testing.T) {
		if err := os.RemoveAll(source); err != nil {
			t.Errorf("removing source directory: %v", err)
		}
		if err := os.RemoveAll(target); err != nil {
			t.Errorf("removing target directory: %v", err)
		}
	}
}

func MustReadFile(t *testing.T, path string) string {
	t.Helper()

	buf, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("error reading file %q: %v", path, err)
	}

	return string(buf)
}

func MustWriteToFile(t *testing.T, path string, contents string) {
	t.Helper()

	err := os.WriteFile(path, []byte(contents), 0600)
	if err != nil {
		t.Fatalf("error writing file %q: %v", path, err)
	}
}

// VerifyRename ensures the source and archive data directories exist, and the
// target directory does not exist.
func VerifyRename(t *testing.T, source, target string) {
	t.Helper()

	archive := target + upgrade.OldSuffix

	PathMustExist(t, source)
	PathMustExist(t, archive)
	PathMustNotExist(t, target)

}

func PathMustExist(t *testing.T, path string) {
	t.Helper()
	checkPath(t, path, true)
}

func PathMustNotExist(t *testing.T, path string) {
	t.Helper()
	checkPath(t, path, false)
}

func checkPath(t *testing.T, path string, shouldExist bool) {
	t.Helper()

	exist, err := upgrade.PathExist(path)
	if err != nil {
		t.Fatalf("unexpected error checking path %q: %v", path, err)
	}

	if shouldExist && !exist {
		t.Fatalf("expected path %q to exist", path)
	}

	if !shouldExist && exist {
		t.Fatalf("expected path %q to not exist", path)
	}
}

func MustGetEnv(key string) string {
	value := os.Getenv(key)
	if value == "" {
		log.Fatalf("Expected $%s to be set", key)
	}

	return value
}

func SetEnv(t *testing.T, envar, value string) func() {
	t.Helper()

	old, reset := os.LookupEnv(envar)

	err := os.Setenv(envar, value)
	if err != nil {
		t.Fatalf("setting %s environment variable to %s: %#v", envar, value, err)
	}

	return func() {
		if reset {
			err := os.Setenv(envar, old)
			if err != nil {
				t.Fatalf("resetting %s environment variable to %s: %#v", envar, old, err)
			}
		} else {
			err := os.Unsetenv(envar)
			if err != nil {
				t.Fatalf("unsetting %s environment variable: %#v", envar, err)
			}
		}
	}
}

// MustClearEnv makes sure envar is cleared, and returns a function to be used
// in a defer that resets the state to what it was prior to this function being called.
func MustClearEnv(t *testing.T, envar string) func() {
	t.Helper()

	old, reset := os.LookupEnv(envar)

	if reset {
		err := os.Unsetenv(envar)
		if err != nil {
			t.Fatalf("unsetting %s environment variable: %#v", envar, err)
		}
	}

	return func() {
		if reset {
			err := os.Setenv(envar, old)
			if err != nil {
				t.Fatalf("resetting %s environment variable to %s: %#v", envar, old, err)
			}
		} else {
			err := os.Unsetenv(envar)
			if err != nil {
				t.Fatalf("unsetting %s environment variable: %#v", envar, err)
			}
		}
	}
}

// MustMakeTablespaceDir returns a temporary tablespace directory, its parent
// dbID directory, and its grandparent tablespace location. The location should
// be removed for cleanup.
func MustMakeTablespaceDir(t *testing.T, tablespaceOid int) (string, string, string) {
	t.Helper()

	// ex: /filespace/demoDataDir0
	filespace := GetTempDir(t, "")

	if tablespaceOid == 0 {
		tablespaceOid = 16386
	}

	// ex /filespace/demoDataDir0/16386/1/GPDB_6_301908232
	tablespace := filepath.Join(filespace, strconv.Itoa(tablespaceOid), "1", "GPDB_6_301908232")
	MustCreateDir(t, tablespace)

	dbID := filepath.Dir(tablespace) // ex: /filespace/demoDataDir0/16386/1
	location := filepath.Dir(dbID)   // ex: /filespace/demoDataDir0/16386
	return tablespace, dbID, location
}

func MustGetExecutablePath(t *testing.T) string {
	t.Helper()

	path, err := os.Executable()
	if err != nil {
		t.Fatalf("failed getting test executable path: %#v", err)
	}

	return filepath.Dir(path)
}

func SetStdin(t *testing.T, input string) func() {
	t.Helper()

	stdinReader, stdinWriter, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}

	origStdin := os.Stdin
	os.Stdin = stdinReader

	_, err = stdinWriter.WriteString(input)
	if err != nil {
		stdinWriter.Close()
		os.Stdin = origStdin
		t.Fatal(err)
	}

	return func() {
		os.Stdin = origStdin
	}
}

func MustGetLog(t *testing.T, process string) string {
	t.Helper()

	logDir, err := utils.GetLogDir()
	if err != nil {
		t.Fatalf("get log dir: %v", err)
	}

	return logger.LogPath(logDir, process)
}

func MustConvertStringToInt(t *testing.T, input string) int {
	t.Helper()

	num, err := strconv.Atoi(input)
	if err != nil {
		t.Fatalf("parse %q", input)
	}

	return num
}
