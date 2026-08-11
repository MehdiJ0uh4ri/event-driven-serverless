# Cold start benchmarks

> **This file is generated.** Run `make bench-report` against a deployed stack
> and it will be overwritten with real measurements. The table below is a
> placeholder describing the method and the shape of the result, not data —
> publishing invented numbers as if they were measured would be worse than
> having none.

## Method

`tools/coldstart_benchmark.py` measures what Lambda **bills** as
`Init Duration`, not a client-side wall-clock guess:

1. **Force a genuine cold start** by publishing a new function version. Every
   version gets its own execution environment, so the next invocation of that
   qualifier cannot be warm. (Mutating an environment variable also forces a new
   sandbox, but it puts the stack into Terraform drift on every run.)
2. **Invoke that qualifier once** with `LogType=Tail`, which returns the last
   4KB of logs inline — no waiting on CloudWatch Logs ingestion.
3. **Parse the `REPORT` line** for `Init Duration`. Its absence means the
   sandbox was reused, and the harness discards that sample loudly rather than
   counting it as a fast cold start.
4. **Clean up the published versions**, because a 25-sample sweep across 9
   functions otherwise leaves 225 copies of the package against the account's
   code storage quota.

Percentiles use **nearest-rank**, not interpolation. With 25 samples, the p99 is
the maximum observed value; pretending otherwise manufactures precision.

The subjects are deliberately dependency-free and near-identical across
languages ([Node](../src/nodejs/src/bench/coldstart.js),
[Python](../src/python/bench/coldstart.py), [Go](../src/go/bench/main.go)) so
what is being compared is the runtime's own initialisation, not three different
bundle sizes.

## Running it

```bash
make bench SAMPLES=25              # print to the terminal
make bench-report SAMPLES=25       # overwrite this file
```

The matrix is defined by `benchmark_memory_sizes` in
[terraform/variables.tf](../terraform/variables.tf) — by default 3 runtimes ×
{128, 512, 1024}MB = 9 functions. It is disabled in prod
(`enable_coldstart_benchmark = false`).

A 25-sample sweep across 9 functions takes roughly 10–15 minutes, most of it
waiting for `publish_version` to reach `Active`.

## Results

_No measurements recorded yet. Run `make bench-report` to populate this section._

| Runtime | Memory | Arch | Package | n | min | p50 | p95 | p99 | max | stdev |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| _pending_ | | | | | | | | | | |

## Reading the results

Three things the numbers will tell you, and what to do about each:

**Runtime choice.** Expect Go (compiled, `provided.al2023`) fastest, Node and
Python close together and several times slower. If your p99 API latency budget
is tight and the hot path is dominated by cold starts, this is the largest
single lever — but rewriting a service in Go to save 200ms at p99 is only worth
it if p99 is actually the constraint. Check [slo.md](slo.md) first.

**Memory sizing.** On Lambda, memory buys CPU, and init is CPU-bound. Cold start
usually improves sharply from 128MB to ~512MB and then flattens. The flattening
point is the efficient size; beyond it you are paying for GB-seconds that do not
buy latency. This is how the sizes in
[functions.tf](../terraform/functions.tf) were chosen — `create-order` runs at
1024MB because its JSON and UUID work is CPU-bound, while `handle-failure` sits
at 256MB because it runs rarely and nobody is waiting on it.

**Package size.** Cold start scales with bytes to download and unpack. If a
measured cold start regresses after a dependency is added, that is the cause.
The `-ldflags "-s -w"` in [build.sh](../scripts/build.sh) strips the Go symbol
table for exactly this reason.

## Caveats worth stating

- **Numbers are region- and time-dependent.** AWS changes runtime internals; a
  measurement from six months ago is a historical note, not a fact.
- **These subjects have no dependencies.** A real function importing the AWS SDK
  and Powertools will be materially slower to init. Benchmark your actual
  functions before making a sizing decision — `--functions <name>` accepts any
  function, not just the bench matrix.
- **`Init Duration` excludes the download.** Lambda does not bill or report the
  time spent fetching the package, so a large package's true cold start is worse
  than this metric suggests.
- **arm64 vs x86_64 is not swept by default.** `lambda_architecture` in
  [variables.tf](../terraform/variables.tf) applies to the whole stack; flip it
  and re-run to compare.
