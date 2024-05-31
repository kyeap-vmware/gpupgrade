// Copyright (c) 2017-2023 VMware, Inc. or its affiliates
// SPDX-License-Identifier: Apache-2.0

package testutils

import (
	"testing"

	sqlmock "github.com/DATA-DOG/go-sqlmock"
	"github.com/blang/semver/v4"
	"github.com/stretchr/testify/mock"

	"github.com/greenplum-db/gpupgrade/greenplum"
)

// finishMock is a defer function to make the sqlmock API a little bit more like
// gomock. Use it like this:
//
//	db, mock, err := sqlmock.New()
//	if err != nil {
//	    t.Fatalf("couldn't create sqlmock: %v", err)
//	}
//	defer finishMock(mock, t)
func FinishMock(mock sqlmock.Sqlmock, t *testing.T) {
	t.Helper()

	if err := mock.ExpectationsWereMet(); err != nil {
		t.Errorf("%v", err)
	}
}

// MockSegmentConfiguration returns a set of sqlmock.Rows that contains the
// expected response to a gp_segment_configuration query.
//
// When changing this implementation, make sure you change MockCluster() to
// match!
func MockSegmentConfiguration() *sqlmock.Rows {
	rows := sqlmock.NewRows([]string{"dbid", "contentid", "port", "hostname", "address", "datadir", "role"})
	rows.AddRow(1, -1, 15432, "mdw", "mdw-1", "/data/coordinator/gpseg-1", "p")
	rows.AddRow(2, 0, 25432, "sdw1", "sdw1-1", "/data/primary/gpseg0", "p")

	return rows
}

// MockCluster returns the Cluster equivalent of MockSegmentConfiguration().
//
// When changing this implementation, make sure you change
// MockSegmentConfiguration() to match!
func MockCluster() *greenplum.Cluster {
	segments := greenplum.SegConfigs{
		{DbID: 1, ContentID: -1, Port: 15432, Hostname: "mdw", Address: "mdw-1", DataDir: "/data/coordinator/gpseg-1", Role: greenplum.PrimaryRole},
		{DbID: 2, ContentID: 0, Port: 25432, Hostname: "sdw1", Address: "sdw1-1", DataDir: "/data/primary/gpseg0", Role: greenplum.PrimaryRole},
	}

	cluster, err := greenplum.NewCluster(segments)
	if err != nil {
		panic(err)
	}

	return &cluster
}

// MockPooler is a mock implementation of the Pooler interface.
type MockPooler struct {
	mock.Mock
	database   string
	version    semver.Version
	jobs       uint
	connString string
}

func (m *MockPooler) Exec(query string, args ...any) error {
	return m.Called(query, args).Error(0)
}

func (m *MockPooler) Query(query string, args ...any) (*greenplum.Rows, error) {
	return m.Called(query, args).Get(0).(*greenplum.Rows), m.Called(query, args).Error(1)
}

func (m *MockPooler) Select(dest any, query string, args ...any) error {
	return m.Called(dest, query, args).Error(0)
}

func (m *MockPooler) Close() {
	m.Called()
}

func (m *MockPooler) Database() string {
	return m.database
}

func (m *MockPooler) Version() semver.Version {
	return m.version
}

func (m *MockPooler) Jobs() uint {
	return m.jobs
}

func (m *MockPooler) ConnString() string {
	return m.connString
}
