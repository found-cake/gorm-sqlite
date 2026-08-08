#!/usr/bin/env bash
set -euo pipefail

repository_root=$(git rev-parse --show-toplevel)
test_root=$(mktemp -d "${TMPDIR:-/tmp}/gorm-tests.XXXXXX")
# A CI runner is thrown away, but this script is also run by hand, where a GORM
# checkout per invocation adds up.
trap 'rm -rf "$test_root"' EXIT
git clone --quiet --depth=1 https://github.com/go-gorm/gorm.git "$test_root/gorm"

cd "$test_root/gorm/tests"
go mod edit -droprequire gorm.io/driver/sqlite
go mod edit -replace github.com/found-cake/gorm-sqlite="$repository_root"
sed -i.bak 's:gorm.io/driver/sqlite:github.com/found-cake/gorm-sqlite:g' tests_test.go
sed -i.bak 's:"gorm.db":"gorm.db?_txlock=immediate\&_pragma=busy_timeout(10000)\&_pragma=journal_mode(WAL)":g' tests_test.go
go mod tidy
CGO_ENABLED=0 go test -count=1 ./...
