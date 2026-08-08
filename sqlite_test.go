package sqlite

import (
	"database/sql"
	"database/sql/driver"
	"fmt"
	"strings"
	"sync"
	"testing"

	"gorm.io/gorm"
	moderncsqlite "modernc.org/sqlite"
)

// This is the DSN of the in-memory SQLite database for these tests.
const InMemoryDSN = "file:testdatabase?mode=memory&cache=shared"

// This is the custom SQLite driver name.
const CustomDriverName = "my_custom_driver"

// Registering a sqlite function and a database/sql driver both panic on a
// duplicate name, and a test binary can run its tests more than once, so the
// process-wide registrations happen exactly once.
var registerTestDriverOnce sync.Once

func registerTestDriver(t *testing.T) {
	t.Helper()

	registerTestDriverOnce.Do(func() {
		moderncsqlite.MustRegisterFunction("my_custom_function", &moderncsqlite.FunctionImpl{
			NArgs:         0,
			Deterministic: true,
			Scalar: func(_ *moderncsqlite.FunctionContext, _ []driver.Value) (driver.Value, error) {
				return "my-result", nil
			},
		})

		defaultDB, err := sql.Open(DriverName, "")
		if err != nil {
			t.Fatalf("failed to open default driver: %v", err)
		}
		sql.Register(CustomDriverName, defaultDB.Driver())
		if err := defaultDB.Close(); err != nil {
			t.Fatalf("failed to close default driver: %v", err)
		}
	})
}

// closeGORM releases a *gorm.DB at the end of a test. A named in-memory
// database lives for as long as one connection to it is open, so leaving it
// open would carry its tables into the next run of the same test binary.
func closeGORM(t *testing.T, db *gorm.DB) {
	t.Helper()

	if db == nil {
		return
	}
	t.Cleanup(func() {
		sqlDB, err := db.DB()
		if err != nil {
			t.Errorf("failed to reach the underlying database: %v", err)
			return
		}
		if err := sqlDB.Close(); err != nil {
			t.Errorf("failed to close database: %v", err)
		}
	})
}

func TestDialector(t *testing.T) {
	registerTestDriver(t)

	rows := []struct {
		description  string
		dialector    *Dialector
		openSuccess  bool
		query        string
		querySuccess bool
	}{
		{
			description: "Default driver",
			dialector: &Dialector{
				DSN: InMemoryDSN,
			},
			openSuccess:  true,
			query:        "SELECT 1",
			querySuccess: true,
		},
		{
			description: "Explicit default driver",
			dialector: &Dialector{
				DriverName: DriverName,
				DSN:        InMemoryDSN,
			},
			openSuccess:  true,
			query:        "SELECT 1",
			querySuccess: true,
		},
		{
			description: "Bad driver",
			dialector: &Dialector{
				DriverName: "not-a-real-driver",
				DSN:        InMemoryDSN,
			},
			openSuccess: false,
		},
		{
			description: "Explicit default driver, custom function",
			dialector: &Dialector{
				DriverName: DriverName,
				DSN:        InMemoryDSN,
			},
			openSuccess:  true,
			query:        "SELECT my_custom_function()",
			querySuccess: true,
		},
		{
			description: "Custom driver",
			dialector: &Dialector{
				DriverName: CustomDriverName,
				DSN:        InMemoryDSN,
			},
			openSuccess:  true,
			query:        "SELECT 1",
			querySuccess: true,
		},
		{
			description: "Custom driver, custom function",
			dialector: &Dialector{
				DriverName: CustomDriverName,
				DSN:        InMemoryDSN,
			},
			openSuccess:  true,
			query:        "SELECT my_custom_function()",
			querySuccess: true,
		},
	}
	for rowIndex, row := range rows {
		t.Run(fmt.Sprintf("%d/%s", rowIndex, row.description), func(t *testing.T) {
			db, err := gorm.Open(row.dialector, &gorm.Config{})
			if !row.openSuccess {
				if err == nil {
					t.Errorf("Expected Open to fail.")
				}
				return
			}

			if err != nil {
				t.Errorf("Expected Open to succeed; got error: %v", err)
			}
			if db == nil {
				t.Errorf("Expected db to be non-nil.")
			}
			closeGORM(t, db)
			if row.query != "" {
				err = db.Exec(row.query).Error
				if !row.querySuccess {
					if err == nil {
						t.Errorf("Expected query to fail.")
					}
					return
				}

				if err != nil {
					t.Errorf("Expected query to succeed; got error: %v", err)
				}
			}
		})
	}
}

func TestExplainQuotesStrings(t *testing.T) {
	out := Dialector{}.Explain("SELECT * FROM t WHERE name = ?", "hello")
	if !strings.Contains(out, "'hello'") {
		t.Errorf("Explain must quote string literals with single quotes, got: %s", out)
	}
}

type explainDefaultModel struct {
	ID   int
	Code string `gorm:"default:hello"`
}

func (explainDefaultModel) TableName() string { return "explain_defaults" }

// GORM embeds string default values into the DDL via Dialector.Explain;
// parseDDL must strip the single quotes (and double quotes from tables
// created by older versions) so migrations stay idempotent.
func TestDefaultValueRoundTrip(t *testing.T) {
	db, err := gorm.Open(Open("file:explain_defaults?mode=memory&cache=shared"), &gorm.Config{})
	if err != nil {
		t.Fatalf("gorm.Open: %v", err)
	}
	t.Cleanup(func() {
		if sqlDB, err := db.DB(); err == nil {
			_ = sqlDB.Close()
		}
	})

	if err := db.AutoMigrate(&explainDefaultModel{}); err != nil {
		t.Fatal(err)
	}
	cols, err := db.Migrator().ColumnTypes(&explainDefaultModel{})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range cols {
		if c.Name() == "code" {
			if dv, ok := c.DefaultValue(); !ok || dv != "hello" {
				t.Errorf("DefaultValue = (%q,%v), want (hello,true)", dv, ok)
			}
		}
	}
	// second AutoMigrate must not rebuild the table
	var before string
	if err := db.Raw("SELECT sql FROM sqlite_master WHERE type='table' AND name='explain_defaults'").Scan(&before).Error; err != nil {
		t.Fatal(err)
	}
	if err := db.AutoMigrate(&explainDefaultModel{}); err != nil {
		t.Fatal(err)
	}
	var after string
	if err := db.Raw("SELECT sql FROM sqlite_master WHERE type='table' AND name='explain_defaults'").Scan(&after).Error; err != nil {
		t.Fatal(err)
	}
	if before != after {
		t.Errorf("DDL changed after second AutoMigrate:\n  before: %s\n  after:  %s", before, after)
	}

	// double quotes from tables created by older driver versions still parse
	d, err := parseDDL("CREATE TABLE `legacy` (`code` text DEFAULT \"hi\")")
	if err != nil {
		t.Fatal(err)
	}
	if dv, ok := d.columns[0].DefaultValue(); !ok || dv != "hi" {
		t.Errorf("legacy DefaultValue = (%q,%v), want (hi,true)", dv, ok)
	}

	// only one outer quote pair is stripped; inner quotes survive
	d, err = parseDDL("CREATE TABLE `q` (`code` text DEFAULT '\"x\"')")
	if err != nil {
		t.Fatal(err)
	}
	if dv, ok := d.columns[0].DefaultValue(); !ok || dv != `"x"` {
		t.Errorf(`quoted DefaultValue = (%q,%v), want ("x",true)`, dv, ok)
	}
}
