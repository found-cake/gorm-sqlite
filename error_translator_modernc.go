package sqlite

import (
	"errors"

	moderncsqlite "modernc.org/sqlite"
)

func (dialector Dialector) Translate(err error) error {
	var sqliteErr *moderncsqlite.Error
	if !errors.As(err, &sqliteErr) || sqliteErr == nil {
		return err
	}

	if translatedErr, found := errCodes[sqliteErr.Code()]; found {
		return translatedErr
	}
	return err
}
