/**
 * Packaging.
 *
 * Terraform zips the already-built source trees. Dependency installation
 * (npm ci --omit=dev, pip install -t, go build) is done by scripts/build.sh
 * *before* terraform runs, so that `terraform plan` stays fast, hermetic and
 * free of local-exec surprises in CI. `make build` chains the two.
 */

# --- Node.js: all handlers share one package (one zip, several entrypoints).
# Simpler to reason about than per-function bundles, and the shared common/
# code is genuinely shared. If cold start on the hot path ever matters more
# than simplicity, split this with esbuild per handler.
data "archive_file" "nodejs" {
  type        = "zip"
  source_dir  = "${local.dist_dir}/nodejs"
  output_path = "${local.dist_dir}/nodejs.zip"
  excludes    = ["*.md", "**/*.test.js", ".eslintrc*"]
}

# --- Python: the audit consumer plus its vendored Powertools.
data "archive_file" "python_audit" {
  type        = "zip"
  source_dir  = "${local.dist_dir}/python-audit"
  output_path = "${local.dist_dir}/python-audit.zip"
  excludes    = ["**/__pycache__/**", "**/*.pyc", "**/*.dist-info/**"]
}

# --- Benchmark packages: one per runtime, deliberately tiny.
data "archive_file" "bench_nodejs" {
  type        = "zip"
  source_file = "${path.module}/../src/nodejs/src/bench/coldstart.js"
  output_path = "${local.dist_dir}/bench-nodejs.zip"
}

data "archive_file" "bench_python" {
  type        = "zip"
  source_file = "${path.module}/../src/python/bench/coldstart.py"
  output_path = "${local.dist_dir}/bench-python.zip"
}

# Go is compiled ahead of time by scripts/build.sh into dist/bench-go/bootstrap.
data "archive_file" "bench_go" {
  type        = "zip"
  source_dir  = "${local.dist_dir}/bench-go"
  output_path = "${local.dist_dir}/bench-go.zip"
}
