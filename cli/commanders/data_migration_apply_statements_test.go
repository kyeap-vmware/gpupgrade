package commanders_test

import (
	"reflect"
	"testing"

	"github.com/greenplum-db/gpupgrade/cli/commanders"
	"github.com/greenplum-db/gpupgrade/utils"
)

func TestIndexStatement(t *testing.T) {
	expectedStatement := &commanders.IndexStatement{
		IndexSchema: "public",
		IndexName:   "index1",
		Table:       "table1",
		IndexDef:    "CREATE INDEX index1 ON table1 (column1);"}

	expectedStr := "-- TYPE: INDEX, SCHEMA: public, TABLE: table1, NAME: index1\nCREATE INDEX index1 ON table1 (column1);\n-- END\n"

	t.Run("Unmarshal", func(t *testing.T) {
		t.Run("Unmarshal with valid data", func(t *testing.T) {
			indexStatement := &commanders.IndexStatement{}
			err := indexStatement.Unmarshal(expectedStr)
			if err != nil {
				t.Errorf("Unmarshal() unexpected error: %v", err)
			}
			if !reflect.DeepEqual(indexStatement, expectedStatement) {
				t.Errorf("Unmarshal()\n%v\nwant:\n%v", indexStatement, expectedStatement)
			}
		})

		t.Run("Unmarshal with invalid data", func(t *testing.T) {
			str := "invalid data"
			err := expectedStatement.Unmarshal(str)
			if err == nil {
				t.Errorf("Unmarshal() expected error, got nil")
			}
		})
		
	})
}

func TestIndexStatements(t *testing.T) {
	expectedStatements := []commanders.IndexStatement{
		{IndexSchema: "public", IndexName: "index1", Table: "table1", IndexDef: "CREATE INDEX index1 ON table1 (column1);"},
		{IndexSchema: "public", IndexName: "index2", Table: "table2", IndexDef: "CREATE INDEX index2 ON table2 (column2);"},
	}
	expectedBytes := []byte("\\c postgres\n-- TYPE: INDEX, SCHEMA: public, TABLE: table1, NAME: index1\nCREATE INDEX index1 ON table1 (column1);\n-- TYPE: INDEX, SCHEMA: public, TABLE: table2, NAME: index2\nCREATE INDEX index2 ON table2 (column2);\n")

	indexes := commanders.NewIndexes()
	indexes.Database = "postgres"
	indexes.Statements = expectedStatements

	t.Run("ReadFromFile", func(t *testing.T) {

		utils.System.ReadFile = func(filename string) ([]byte, error) {
			if filename != "filename" {
				t.Errorf("ReadFromFile() filename\n%s\nwant:\nfilename", filename)
			} 
			return expectedBytes, nil
		}
		defer utils.ResetSystemFunctions()
		indexes := commanders.NewIndexes()
		err := indexes.ReadFromFile("filename")
		if err != nil {
			t.Errorf("ReadFromFile() unexpected error: %v", err)
		}
		if indexes.Count() != 2 {
			t.Errorf("indexes.Count()\n%d\nwant:\n2", indexes.Count())
		}
		if indexes.Database != "postgres" {
			t.Errorf("indexes.Database\n%s\nwant:\npostgres", indexes.Database)
		}
		if !reflect.DeepEqual(indexes.Statements, expectedStatements) {
			t.Errorf("indexes.Statements\n%v\nwant:\n%v", indexes.Statements, expectedStatements)
		}
	})
}
