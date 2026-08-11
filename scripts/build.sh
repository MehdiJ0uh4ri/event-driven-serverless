#!/usr/bin/env bash
#
# Build every deployment artefact into dist/, ready for `terraform apply`.
#
# Kept out of Terraform on purpose: local-exec provisioners make plans
# non-hermetic and hide build failures behind confusing Terraform errors.
# Run this first (or just use `make build`).
#
# Reproducibility: dependencies are installed from lockfiles, and zip mtimes
# are normalised so an unchanged source tree produces an unchanged hash and
# Terraform does not redeploy for no reason.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST="${ROOT}/dist"
ARCH="${LAMBDA_ARCH:-arm64}"

# Fixed timestamp for every file we stage, so hashes are content-addressed.
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-1700000000}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required but not on PATH"; }

log "Cleaning dist/"
rm -rf "${DIST}"
mkdir -p "${DIST}"

# ---------------------------------------------------------------------------
# Node.js application bundle
# ---------------------------------------------------------------------------
log "Building Node.js bundle"
need node
need npm

NODE_SRC="${ROOT}/src/nodejs"
NODE_OUT="${DIST}/nodejs"
mkdir -p "${NODE_OUT}"

cp -R "${NODE_SRC}/src" "${NODE_OUT}/src"
cp "${NODE_SRC}/package.json" "${NODE_OUT}/package.json"
[[ -f "${NODE_SRC}/package-lock.json" ]] && cp "${NODE_SRC}/package-lock.json" "${NODE_OUT}/"

pushd "${NODE_OUT}" >/dev/null
if [[ -f package-lock.json ]]; then
  npm ci --omit=dev --no-audit --no-fund
else
  # First run in a fresh clone: generate the lockfile, then commit it.
  npm install --omit=dev --no-audit --no-fund
  cp package-lock.json "${NODE_SRC}/package-lock.json"
fi
# The benchmark subject must stay dependency-free; it is packaged separately.
rm -rf src/bench
popd >/dev/null

# ---------------------------------------------------------------------------
# Python audit consumer
# ---------------------------------------------------------------------------
log "Building Python audit bundle"
need python3

PY_SRC="${ROOT}/src/python/audit"
PY_OUT="${DIST}/python-audit"
mkdir -p "${PY_OUT}"

cp "${PY_SRC}/handler.py" "${PY_OUT}/"

# --platform/--only-binary keeps manylinux wheels for the Lambda runtime even
# when building on macOS or Windows. Without it, a local build silently ships
# the wrong native wheels.
PY_PLATFORM="manylinux2014_aarch64"
[[ "${ARCH}" == "x86_64" ]] && PY_PLATFORM="manylinux2014_x86_64"

python3 -m pip install \
  --requirement "${PY_SRC}/requirements.txt" \
  --target "${PY_OUT}" \
  --platform "${PY_PLATFORM}" \
  --python-version 3.12 \
  --implementation cp \
  --only-binary=:all: \
  --upgrade \
  --quiet

# Trim what Lambda never needs; typically halves the package.
find "${PY_OUT}" -type d -name "__pycache__" -prune -exec rm -rf {} + 2>/dev/null || true
find "${PY_OUT}" -type d -name "*.dist-info" -prune -exec rm -rf {} + 2>/dev/null || true
find "${PY_OUT}" -type d -name "tests" -prune -exec rm -rf {} + 2>/dev/null || true

# ---------------------------------------------------------------------------
# Benchmark subjects
# ---------------------------------------------------------------------------
log "Building benchmark subjects"

# Node and Python benchmarks are single files; terraform/build.tf zips them
# straight from src/. Go must be compiled.
GO_OUT="${DIST}/bench-go"
mkdir -p "${GO_OUT}"

if command -v go >/dev/null 2>&1; then
  GOARCH="arm64"
  [[ "${ARCH}" == "x86_64" ]] && GOARCH="amd64"

  pushd "${ROOT}/src/go" >/dev/null
  # -ldflags "-s -w" strips the symbol table and DWARF data: a smaller binary
  # is a measurably faster cold start, which is the whole point here.
  CGO_ENABLED=0 GOOS=linux GOARCH="${GOARCH}" \
    go build -trimpath -ldflags "-s -w" -o "${GO_OUT}/bootstrap" ./bench
  chmod +x "${GO_OUT}/bootstrap"
  popd >/dev/null
  log "Go benchmark built for linux/${GOARCH}"
else
  # Go is optional: the Node and Python benchmarks still run without it.
  # A placeholder keeps terraform's archive_file data source happy.
  printf '#!/bin/sh\necho "go toolchain was not available at build time" >&2\nexit 1\n' \
    > "${GO_OUT}/bootstrap"
  chmod +x "${GO_OUT}/bootstrap"
  log "WARNING: go not found -- the Go benchmark will be a non-functional stub"
fi

# ---------------------------------------------------------------------------
# Normalise timestamps so identical sources produce identical zips
# ---------------------------------------------------------------------------
log "Normalising artefact timestamps"
find "${DIST}" -exec touch -d "@${SOURCE_DATE_EPOCH}" {} + 2>/dev/null || \
  find "${DIST}" -exec touch -t 202311141122.20 {} + 2>/dev/null || true

log "Build complete:"
du -sh "${DIST}"/* 2>/dev/null || ls -la "${DIST}"
