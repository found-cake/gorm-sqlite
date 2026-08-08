package sqlite

import (
	"net/url"
	"strings"
)

// openDSN returns the DSN to hand to sql.Open.
//
// The compatibility defaults below name parameters that only modernc.org/sqlite
// understands, so they are added for the driver this package registers and for
// nothing else. A caller that set DriverName registered that driver itself, and
// its DSN is its own business.
func (dialector Dialector) openDSN() string {
	if dialector.DriverName != DriverName {
		return dialector.DSN
	}
	return injectDSNParams(dialector.DSN)
}

func injectDSNParams(dsn string) string {
	path := dsn
	rawQuery := ""
	if index := strings.IndexRune(dsn, '?'); index >= 0 {
		path = dsn[:index]
		rawQuery = dsn[index+1:]
	}
	if path == "" {
		return dsn
	}

	values, err := url.ParseQuery(rawQuery)
	if err != nil {
		return dsn
	}

	additions := make([]string, 0, 4)
	addIfMissing := func(key, value string) {
		if _, ok := values[key]; !ok {
			additions = append(additions, key+"="+value)
		}
	}
	addIfMissing("_texttotime", "1")
	addIfMissing("_inttotime", "1")
	addIfMissing("_time_format", "sqlite")

	// A _pragma value is a statement such as "busy_timeout(5000)", so compare
	// against the pragma name alone. Matching the whole value as a substring
	// would also accept an unrelated pragma that merely ends in busy_timeout.
	hasBusyTimeout := false
	for _, pragma := range values["_pragma"] {
		name := strings.ToLower(strings.TrimSpace(pragma))
		if index := strings.IndexAny(name, "(="); index >= 0 {
			name = strings.TrimSpace(name[:index])
		}
		if name == "busy_timeout" {
			hasBusyTimeout = true
			break
		}
	}
	if !hasBusyTimeout {
		additions = append(additions, "_pragma=busy_timeout(5000)")
	}

	if len(additions) == 0 {
		return dsn
	}
	if rawQuery == "" {
		return path + "?" + strings.Join(additions, "&")
	}
	return path + "?" + rawQuery + "&" + strings.Join(additions, "&")
}
