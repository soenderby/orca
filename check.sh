#!/usr/bin/env bash
set -euo pipefail

MIN_GO_VERSION="${MIN_GO_VERSION:-1.26.1}"

if ! command -v go >/dev/null 2>&1; then
  echo "go not found on PATH. Install Go globally (>= ${MIN_GO_VERSION}) and retry." >&2
  exit 1
fi

installed_raw="$(go env GOVERSION 2>/dev/null || true)"
if [[ -z "${installed_raw}" ]]; then
  installed_raw="$(go version | awk '{print $3}')"
fi
installed_version="${installed_raw#go}"
if [[ -z "${installed_version}" ]]; then
  echo "unable to determine installed Go version" >&2
  exit 1
fi

if [[ "$(printf '%s\n%s\n' "${MIN_GO_VERSION}" "${installed_version}" | sort -V | head -n1)" != "${MIN_GO_VERSION}" ]]; then
  echo "go ${installed_version} is too old; require >= ${MIN_GO_VERSION}" >&2
  exit 1
fi

echo "Using: go ${installed_version}"
go version

echo "=== vet ==="
go vet ./...

echo "=== test ==="
go test ./...

if [[ -d "./cmd/orca" ]]; then
  echo "=== build ==="
  go build -o orca ./cmd/orca/
fi

echo ""
echo "All checks passed"
