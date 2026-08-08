# GORM SQLite Driver for modernc.org/sqlite

[![CI](https://github.com/found-cake/gorm-sqlite/actions/workflows/ci.yml/badge.svg)](https://github.com/found-cake/gorm-sqlite/actions/workflows/ci.yml)

A CGO-free fork of the official [GORM SQLite driver](https://github.com/go-gorm/sqlite), powered by [modernc.org/sqlite](https://pkg.go.dev/modernc.org/sqlite).

## Quick start

```shell
go get github.com/found-cake/gorm-sqlite
```

```go
import (
  "github.com/found-cake/gorm-sqlite"
  "gorm.io/gorm"
)

db, err := gorm.Open(sqlite.Open("gorm.db"), &gorm.Config{})
```

The public API stays compatible with the official driver. The default driver name is `sqlite`, and compatibility DSN defaults for time conversion and a five-second busy timeout are added without overriding explicitly supplied values.

## Maintenance

Upstream maintenance is automated by the [Sync upstream workflow](.github/workflows/sync-upstream.yml), implemented by [sync-upstream-simple.sh](.github/scripts/sync-upstream-simple.sh).
