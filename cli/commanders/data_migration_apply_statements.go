package commanders

import (
	"bufio"
	"fmt"
	"strings"
	"sync"

	"github.com/greenplum-db/gpupgrade/greenplum"
	"github.com/greenplum-db/gpupgrade/utils"
	"github.com/greenplum-db/gpupgrade/utils/errorlist"
)

// TODO: The Statement interface is defined with the intent
// of having multiple types of statements in the future.
type Statement interface {
	FQN() string
	Schema() string
	Name() string
	OwningTable() string
	Definition() string
	Parse(statement string) error
}

type Indexes struct {
	Name        string
	Description string
	Database    string
	Statements  []IndexStatement
}

func NewIndexes() *Indexes {
	return &Indexes{Database: "", Statements: []IndexStatement{}}
}

func (i *Indexes) Count() uint {
	if i.Statements == nil {
		return 0
	}
	return uint(len(i.Statements))
}

func (i *Indexes) ReadFromFile(inputFile string) error {
	indexPrefix := "-- TYPE: INDEX, "
	if i.Statements == nil {
		return fmt.Errorf("index statements are nil")
	}

	contents, err := utils.System.ReadFile(inputFile)
	if err != nil {
		return err
	}

	contentsStr := string(contents)

	// Parse the database name from the script
	scanner := bufio.NewScanner(strings.NewReader(contentsStr))
	for scanner.Scan() {
		line := scanner.Text()
		if strings.HasPrefix(line, "\\c") {
			i.Database = strings.TrimSpace(strings.TrimPrefix(line, "\\c"))
			break
		}
	}
	if i.Database == "" {
		return fmt.Errorf("unable to parse database from script %s", inputFile)
	}

	parts := strings.Split(contentsStr, "\n"+indexPrefix)

	if len(parts) <= 1 {
		return fmt.Errorf("Failed to apply data migration script. No index statements found in %q.", inputFile)
	}

	for _, part := range parts[1:] {
		statement := IndexStatement{}
		err := statement.Unmarshal(indexPrefix + part)
		if err != nil {
			return err
		}
		i.Statements = append(i.Statements, statement)
	}

	return nil
}

// Index statements are grouped together by their owning table and applied
// in parallel. This is done to avoid deadlocks when executing multiple
// DROP INDEX statements to the same table, because the DROP INDEX statement
// acquires an ACCESS EXCLUSIVE lock on the table. For convenience, the
// CREATE INDEX statements for both root and child tables are handled in
// the same fashion.
func (i *Indexes) Apply(scriptPath string, port int, jobs uint) error {
	var errs error
	err := i.ReadFromFile(scriptPath)
	if err != nil {
		return err
	}

	batches := make(map[string][]string)

	for _, statement := range i.Statements {
		batches[statement.OwningTable()] = append(batches[statement.OwningTable()], statement.Definition())
	}

	pool, err := greenplum.NewPoolerFunc(greenplum.Port(port), greenplum.Database(i.Database), greenplum.Jobs(jobs))
	if err != nil {
		return err
	}
	defer pool.Close()

	errChan := make(chan error, i.Count())
	batchChan := make(chan []string, len(batches))
	jobs = min(pool.Jobs(), i.Count())

	var wg sync.WaitGroup
	for j := 0; j < int(jobs); j++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for statements := range batchChan {
				for _, s := range statements {
					execErr := pool.Exec(s)
					if execErr != nil {
						errChan <- fmt.Errorf("URI: %s: executing statement %q: %w", pool.ConnString(), s, execErr)
					}
				}
			}
		}()
	}

	for _, batch := range batches {
		batchChan <- batch
	}

	close(batchChan)
	wg.Wait()
	close(errChan)

	for e := range errChan {
		errs = errorlist.Append(errs, e)
	}

	if errs != nil {
		return errs
	}
	return nil
}

type IndexStatement struct {
	IndexSchema string
	Table       string
	IndexName   string
	IndexDef    string
}

func (is *IndexStatement) FQN() string {
	return fmt.Sprintf("%s.%s", is.IndexSchema, is.IndexName)
}

func (is *IndexStatement) Schema() string {
	return is.IndexSchema
}

func (is *IndexStatement) Name() string {
	return is.IndexName
}

func (is *IndexStatement) OwningTable() string {
	return is.Table
}

func (is *IndexStatement) Definition() string {
	return is.IndexDef
}

func (is *IndexStatement) Unmarshal(statement string) error {

	if is == nil {
		return fmt.Errorf("index statement is nil")
	}

	lines := strings.Split(statement, "\n")
	header := lines[0]
	if !strings.HasPrefix(header, "-- TYPE: INDEX") {
		return fmt.Errorf("failed to unmarshal index statement: invalid header")
	}

	parts := strings.Split(header, ", ")
	if len(parts) != 4 {
		return fmt.Errorf("failed to unmarshal index statement: invalid header")
	}

	schema := strings.TrimPrefix(parts[1], "SCHEMA: ")
	table := strings.TrimPrefix(parts[2], "TABLE: ")
	name := strings.TrimPrefix(parts[3], "NAME: ")

	is.IndexSchema = strings.TrimSpace(schema)
	is.Table = strings.TrimSpace(table)
	is.IndexName = strings.TrimSpace(name)
	is.IndexDef = lines[1]

	if is.Schema() == "" || is.OwningTable() == "" || is.Name() == "" || is.Definition() == "" {
		return fmt.Errorf("failed to unmarshal index statement: missing required fields")
	}

	return nil
}
