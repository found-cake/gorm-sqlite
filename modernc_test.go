package sqlite

import (
	"database/sql"
	"database/sql/driver"
	"fmt"
	"strings"
	"sync"
	"testing"
)

func TestInjectDSNParams(t *testing.T) {
	tests := []struct {
		name    string
		dsn     string
		exact   string
		want    []string
		notWant []string
	}{
		{
			name: "adds compatibility defaults",
			dsn:  ":memory:",
			want: []string{
				"_texttotime=1",
				"_inttotime=1",
				"_time_format=sqlite",
				"_pragma=busy_timeout(5000)",
			},
		},
		{
			name: "preserves user values",
			dsn:  "test.db?_time_format=datetime&_pragma=busy_timeout(10000)",
			want: []string{
				"_time_format=datetime",
				"_pragma=busy_timeout(10000)",
				"_texttotime=1",
				"_inttotime=1",
			},
			notWant: []string{"_time_format=sqlite", "busy_timeout(5000)"},
		},
		{
			name: "an unrelated pragma does not pass for busy_timeout",
			dsn:  "test.db?_pragma=not_busy_timeout(1)",
			want: []string{"_pragma=busy_timeout(5000)", "_pragma=not_busy_timeout(1)"},
		},
		{
			name:  "leaves malformed query unchanged",
			dsn:   "test.db?key=%ZZ",
			exact: "test.db?key=%ZZ",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := injectDSNParams(tt.dsn)
			if tt.exact != "" {
				if got != tt.exact {
					t.Errorf("injectDSNParams(%q) = %q; want %q", tt.dsn, got, tt.exact)
				}
				return
			}
			for _, want := range tt.want {
				if !strings.Contains(got, want) {
					t.Errorf("injectDSNParams(%q) = %q; want %q", tt.dsn, got, want)
				}
			}
			for _, notWant := range tt.notWant {
				if strings.Contains(got, notWant) {
					t.Errorf("injectDSNParams(%q) = %q; must not contain %q", tt.dsn, got, notWant)
				}
			}
		})
	}
}

// dsnRecorder is a driver that fails every Open but remembers the DSN it was
// asked for, which is the only thing these tests care about.
type dsnRecorder struct {
	mu   sync.Mutex
	seen []string
}

func (r *dsnRecorder) Open(name string) (driver.Conn, error) {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.seen = append(r.seen, name)
	return nil, fmt.Errorf("dsnRecorder never connects")
}

func (r *dsnRecorder) last(t *testing.T) string {
	t.Helper()
	r.mu.Lock()
	defer r.mu.Unlock()
	if len(r.seen) == 0 {
		t.Fatal("the recording driver was never opened")
	}
	return r.seen[len(r.seen)-1]
}

var (
	recorderOnce sync.Once
	recorder     = &dsnRecorder{}
)

// registerRecorder registers the recording driver once per process. database/sql
// panics on a duplicate name, and tests may run more than once per binary.
func registerRecorder(t *testing.T) string {
	t.Helper()
	const name = "gorm-sqlite-dsn-recorder"
	recorderOnce.Do(func() { sql.Register(name, recorder) })
	return name
}

// A caller that sets DriverName registered that driver itself, and it need not
// be modernc.org/sqlite, so its DSN must arrive exactly as written.
func TestOpenDSNLeavesACustomDriverAlone(t *testing.T) {
	const dsn = "file:custom_driver_audit?mode=memory&cache=shared"
	driverName := registerRecorder(t)

	db, err := sql.Open(driverName, Dialector{DriverName: driverName, DSN: dsn}.openDSN())
	if err != nil {
		t.Fatalf("sql.Open: %v", err)
	}
	t.Cleanup(func() { _ = db.Close() })
	_ = db.Ping() // the recorder refuses to connect; the DSN is what matters

	if got := recorder.last(t); got != dsn {
		t.Errorf("a custom driver received %q; want the DSN unchanged: %q", got, dsn)
	}
}

func TestOpenDSNAddsDefaultsForTheDefaultDriver(t *testing.T) {
	const dsn = "file:default_driver_audit?mode=memory&cache=shared"

	got := Dialector{DriverName: DriverName, DSN: dsn}.openDSN()
	if !strings.Contains(got, "_texttotime=1") {
		t.Errorf("the default driver lost its compatibility defaults: %q", got)
	}

	// An empty DriverName means the default driver too, but Initialize is what
	// fills it in, so openDSN sees it empty and must not guess.
	if got := (Dialector{DSN: dsn}).openDSN(); got != dsn {
		t.Errorf("openDSN(%q) with no DriverName = %q; want it untouched", dsn, got)
	}
}
