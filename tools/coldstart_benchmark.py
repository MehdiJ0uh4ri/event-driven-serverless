#!/usr/bin/env python3
"""Cold-start benchmark harness: Node.js vs Python vs Go, across memory sizes.

Measures what Lambda actually bills as `Init Duration`, not a wall-clock guess
from the client side. Method:

  1. Publish a new function version. Every version gets its own execution
     environment, so the next invocation of that qualifier is guaranteed cold.
     (Mutating an env var also works but puts the stack into Terraform drift.)
  2. Invoke the published version once.
  3. Read the REPORT line from CloudWatch Logs and pull `Init Duration` out.
  4. Repeat N times per function, then report p50/p95/p99.

Percentiles use the nearest-rank method on the raw samples -- with 20-50
samples, interpolation invents precision that is not there.

Usage
-----
    python tools/coldstart_benchmark.py --discover --samples 25
    python tools/coldstart_benchmark.py --functions order-platform-dev-bench-go-512 --samples 50
    python tools/coldstart_benchmark.py --discover --format markdown --output docs/benchmarks.md

Requires: boto3, and credentials with lambda:PublishVersion, lambda:InvokeFunction,
lambda:ListFunctions, logs:FilterLogEvents on the benchmark functions.
"""

from __future__ import annotations

import argparse
import base64
import json
import math
import re
import statistics
import sys
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

try:
    import boto3
    from botocore.config import Config
    from botocore.exceptions import ClientError
except ImportError:  # pragma: no cover
    print("boto3 is required: pip install boto3", file=sys.stderr)
    raise SystemExit(2)

# Lambda writes one REPORT line per invocation. Init Duration is present only
# on cold starts, which is exactly the signal we want.
REPORT_RE = re.compile(
    r"Duration:\s*(?P<duration>[\d.]+)\s*ms.*?"
    r"Billed Duration:\s*(?P<billed>\d+)\s*ms.*?"
    r"Memory Size:\s*(?P<memory>\d+)\s*MB.*?"
    r"Max Memory Used:\s*(?P<max_memory>\d+)\s*MB"
    r"(?:.*?Init Duration:\s*(?P<init>[\d.]+)\s*ms)?",
    re.DOTALL,
)

RUNTIME_LABELS = {
    "nodejs20.x": "Node.js 20",
    "nodejs22.x": "Node.js 22",
    "python3.12": "Python 3.12",
    "python3.11": "Python 3.11",
    "provided.al2023": "Go (al2023)",
}


@dataclass
class Sample:
    init_ms: float | None
    duration_ms: float
    billed_ms: int
    max_memory_mb: int
    request_id: str


@dataclass
class Result:
    function_name: str
    runtime: str
    memory_mb: int
    architecture: str
    package_bytes: int
    samples: list[Sample] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)

    @property
    def init_times(self) -> list[float]:
        return sorted(s.init_ms for s in self.samples if s.init_ms is not None)

    @property
    def cold_start_count(self) -> int:
        return len(self.init_times)

    def percentile(self, p: float) -> float | None:
        """Nearest-rank percentile. With 20-50 samples, interpolating between
        neighbours invents precision the data does not have."""
        data = self.init_times
        if not data:
            return None
        rank = max(1, min(len(data), math.ceil(p / 100 * len(data))))
        return data[rank - 1]

    def stats(self) -> dict[str, float | None]:
        data = self.init_times
        if not data:
            return dict.fromkeys(("min", "p50", "p90", "p95", "p99", "max", "mean", "stdev"))
        return {
            "min": data[0],
            "p50": self.percentile(50),
            "p90": self.percentile(90),
            "p95": self.percentile(95),
            "p99": self.percentile(99),
            "max": data[-1],
            "mean": statistics.fmean(data),
            "stdev": statistics.stdev(data) if len(data) > 1 else 0.0,
        }

    @property
    def warm_duration_p50(self) -> float | None:
        warm = sorted(s.duration_ms for s in self.samples if s.init_ms is None)
        return warm[len(warm) // 2] if warm else None


class Benchmarker:
    def __init__(self, region: str | None = None, log_wait_seconds: float = 6.0):
        cfg = Config(retries={"max_attempts": 5, "mode": "adaptive"})
        self.lambda_client = boto3.client("lambda", region_name=region, config=cfg)
        self.logs = boto3.client("logs", region_name=region, config=cfg)
        self.log_wait_seconds = log_wait_seconds

    # -- discovery ---------------------------------------------------------
    def discover(self, name_filter: str = "bench") -> list[dict]:
        """Find deployed benchmark functions by name substring."""
        found: list[dict] = []
        paginator = self.lambda_client.get_paginator("list_functions")
        for page in paginator.paginate():
            for fn in page["Functions"]:
                if name_filter in fn["FunctionName"]:
                    found.append(fn)
        return sorted(found, key=lambda f: (f["Runtime"], f["MemorySize"]))

    def describe(self, function_name: str) -> dict:
        return self.lambda_client.get_function_configuration(FunctionName=function_name)

    # -- the actual measurement -------------------------------------------
    def _force_cold_version(self, function_name: str, iteration: int) -> str:
        """Publish a version so the next invoke of it must be a cold start."""
        response = self.lambda_client.publish_version(
            FunctionName=function_name,
            Description=f"coldstart benchmark sample {iteration} at {datetime.now(timezone.utc).isoformat()}",
        )
        return response["Version"]

    def _invoke(self, function_name: str, qualifier: str) -> tuple[str, str]:
        """Invoke and return (requestId, base64 log tail)."""
        response = self.lambda_client.invoke(
            FunctionName=function_name,
            Qualifier=qualifier,
            InvocationType="RequestResponse",
            LogType="Tail",  # returns the last 4KB of logs inline -- no waiting
            Payload=json.dumps({"ping": "benchmark"}).encode(),
        )
        request_id = response["ResponseMetadata"]["RequestId"]
        log_result = response.get("LogResult", "")
        if response.get("FunctionError"):
            payload = response["Payload"].read().decode("utf-8", errors="replace")
            raise RuntimeError(f"function returned an error: {payload[:400]}")
        return request_id, log_result

    @staticmethod
    def _parse_report(log_text: str) -> Sample | None:
        match = REPORT_RE.search(log_text)
        if not match:
            return None
        init = match.group("init")
        request_id_match = re.search(r"RequestId:\s*([0-9a-f-]{36})", log_text)
        return Sample(
            init_ms=float(init) if init else None,
            duration_ms=float(match.group("duration")),
            billed_ms=int(match.group("billed")),
            max_memory_mb=int(match.group("max_memory")),
            request_id=request_id_match.group(1) if request_id_match else "",
        )

    def _cleanup_versions(self, function_name: str, keep: int = 0) -> int:
        """Delete the versions we published. Lambda caps total code storage per
        account, and a benchmark run creates dozens of copies of the package."""
        deleted = 0
        paginator = self.lambda_client.get_paginator("list_versions_by_function")
        versions = []
        for page in paginator.paginate(FunctionName=function_name):
            versions.extend(v["Version"] for v in page["Versions"] if v["Version"] != "$LATEST")

        for version in sorted(versions, key=int)[: max(0, len(versions) - keep)]:
            try:
                self.lambda_client.delete_function(FunctionName=function_name, Qualifier=version)
                deleted += 1
            except ClientError as exc:
                # A version still referenced by an alias cannot be deleted; fine.
                if exc.response["Error"]["Code"] not in ("ResourceConflictException", "ResourceNotFoundException"):
                    raise
        return deleted

    def run(self, function_name: str, samples: int, cleanup: bool = True, verbose: bool = True) -> Result:
        config = self.describe(function_name)
        result = Result(
            function_name=function_name,
            runtime=config["Runtime"],
            memory_mb=config["MemorySize"],
            architecture=config.get("Architectures", ["x86_64"])[0],
            package_bytes=config.get("CodeSize", 0),
        )

        label = RUNTIME_LABELS.get(result.runtime, result.runtime)
        if verbose:
            print(
                f"  {label:<16} {result.memory_mb:>5}MB  {result.architecture:<8} "
                f"pkg {result.package_bytes / 1024:>7.1f}KB  ",
                end="",
                flush=True,
            )

        for i in range(samples):
            try:
                version = self._force_cold_version(function_name, i)
                # Publishing returns before the version is fully available.
                waiter = self.lambda_client.get_waiter("function_active")
                waiter.wait(
                    FunctionName=function_name,
                    Qualifier=version,
                    WaiterConfig={"Delay": 1, "MaxAttempts": 30},
                )

                _, log_result = self._invoke(function_name, version)
                log_text = base64.b64decode(log_result).decode("utf-8", errors="replace")
                sample = self._parse_report(log_text)

                if sample is None:
                    result.errors.append(f"sample {i}: no REPORT line in the log tail")
                elif sample.init_ms is None:
                    # Should not happen on a freshly published version, but if
                    # Lambda reused a sandbox we must not silently count it.
                    result.errors.append(f"sample {i}: warm invocation, discarded")
                    result.samples.append(sample)
                else:
                    result.samples.append(sample)
                    if verbose:
                        print("." if i % 5 else str(i // 5), end="", flush=True)

            # One bad sample must not abort a 15-minute sweep; record and move on.
            except Exception as exc:  # noqa: BLE001
                result.errors.append(f"sample {i}: {type(exc).__name__}: {exc}")
                if verbose:
                    print("x", end="", flush=True)

        if cleanup:
            removed = self._cleanup_versions(function_name)
            if verbose:
                print(f"  (cleaned {removed} versions)", end="")

        if verbose:
            stats = result.stats()
            if stats["p50"] is not None:
                print(
                    f"\n{'':<22}p50 {stats['p50']:>7.1f}ms  "
                    f"p95 {stats['p95']:>7.1f}ms  p99 {stats['p99']:>7.1f}ms  "
                    f"(n={result.cold_start_count})"
                )
            else:
                print(f"\n{'':<22}no cold-start samples collected")

        return result


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------
def render_table(results: list[Result]) -> str:
    out = ["", "  Cold start init duration (ms)", "  " + "─" * 96]
    out.append(
        f"  {'RUNTIME':<16}{'MEM':>6}{'ARCH':>9}{'PKG KB':>9}{'N':>5}"
        f"{'MIN':>9}{'p50':>9}{'p95':>9}{'p99':>9}{'MAX':>9}{'STDEV':>8}"
    )
    out.append("  " + "─" * 96)

    for r in sorted(results, key=lambda x: (x.runtime, x.memory_mb)):
        s = r.stats()
        label = RUNTIME_LABELS.get(r.runtime, r.runtime)
        if s["p50"] is None:
            out.append(f"  {label:<16}{r.memory_mb:>6}{r.architecture:>9}{'':>9}{0:>5}   no samples")
            continue
        out.append(
            f"  {label:<16}{r.memory_mb:>6}{r.architecture:>9}"
            f"{r.package_bytes / 1024:>9.1f}{r.cold_start_count:>5}"
            f"{s['min']:>9.1f}{s['p50']:>9.1f}{s['p95']:>9.1f}{s['p99']:>9.1f}{s['max']:>9.1f}{s['stdev']:>8.1f}"
        )

    out.append("  " + "─" * 96)

    # Relative comparison at the most common memory size.
    by_memory: dict[int, list[Result]] = {}
    for r in results:
        if r.stats()["p50"] is not None:
            by_memory.setdefault(r.memory_mb, []).append(r)

    for memory, group in sorted(by_memory.items()):
        if len(group) < 2:
            continue
        fastest = min(group, key=lambda r: r.stats()["p50"])
        out.append(f"\n  Relative p50 at {memory}MB (baseline: {RUNTIME_LABELS.get(fastest.runtime, fastest.runtime)}):")
        for r in sorted(group, key=lambda r: r.stats()["p50"]):
            ratio = r.stats()["p50"] / fastest.stats()["p50"]
            bar = "█" * int(min(60, ratio * 8))
            out.append(f"    {RUNTIME_LABELS.get(r.runtime, r.runtime):<16} {bar:<60} {ratio:>5.2f}x")

    errors = [(r.function_name, e) for r in results for e in r.errors]
    if errors:
        out.append(f"\n  {len(errors)} sample error(s):")
        for fn, err in errors[:10]:
            out.append(f"    {fn}: {err}")
        if len(errors) > 10:
            out.append(f"    ... and {len(errors) - 10} more")

    out.append("")
    return "\n".join(out)


def render_markdown(results: list[Result], samples: int) -> str:
    now = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    lines = [
        "# Cold start benchmarks",
        "",
        f"_Generated {now} by `tools/coldstart_benchmark.py`, {samples} forced cold starts per function._",
        "",
        "Method: publish a new function version (guaranteeing a fresh execution",
        "environment), invoke it once, and read `Init Duration` from the Lambda",
        "REPORT line. Percentiles are nearest-rank over the raw samples.",
        "",
        "## Results",
        "",
        "| Runtime | Memory | Arch | Package | n | min | **p50** | **p95** | **p99** | max | stdev |",
        "| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |",
    ]

    for r in sorted(results, key=lambda x: (x.memory_mb, x.runtime)):
        s = r.stats()
        label = RUNTIME_LABELS.get(r.runtime, r.runtime)
        if s["p50"] is None:
            lines.append(f"| {label} | {r.memory_mb}MB | {r.architecture} | — | 0 | — | — | — | — | — | — |")
            continue
        lines.append(
            f"| {label} | {r.memory_mb}MB | {r.architecture} | {r.package_bytes / 1024:,.0f}KB | "
            f"{r.cold_start_count} | {s['min']:.1f} | **{s['p50']:.1f}** | **{s['p95']:.1f}** | "
            f"**{s['p99']:.1f}** | {s['max']:.1f} | {s['stdev']:.1f} |"
        )

    lines.extend(["", "All figures in milliseconds.", ""])

    # Only state conclusions the data actually supports.
    valid = [r for r in results if r.stats()["p50"] is not None]
    if len(valid) >= 2:
        fastest = min(valid, key=lambda r: r.stats()["p50"])
        slowest = max(valid, key=lambda r: r.stats()["p50"])
        lines.extend(
            [
                "## Observations",
                "",
                f"- Fastest cold start: **{RUNTIME_LABELS.get(fastest.runtime, fastest.runtime)} "
                f"@ {fastest.memory_mb}MB** at {fastest.stats()['p50']:.1f}ms p50.",
                f"- Slowest: **{RUNTIME_LABELS.get(slowest.runtime, slowest.runtime)} "
                f"@ {slowest.memory_mb}MB** at {slowest.stats()['p50']:.1f}ms p50 "
                f"({slowest.stats()['p50'] / fastest.stats()['p50']:.1f}x).",
                "- p99 is the number that matters for a user-facing API: it is what",
                "  the unluckiest 1% of requests experience after a scale-up event.",
                "",
            ]
        )

    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--region", help="AWS region (defaults to the ambient config)")
    parser.add_argument("--discover", action="store_true", help="Auto-discover functions with 'bench' in the name")
    parser.add_argument("--name-filter", default="bench", help="Substring used by --discover")
    parser.add_argument("--functions", nargs="+", help="Explicit function names to benchmark")
    parser.add_argument("--samples", type=int, default=20, help="Forced cold starts per function")
    parser.add_argument("--no-cleanup", action="store_true", help="Keep the published versions")
    parser.add_argument("--format", choices=["table", "json", "markdown"], default="table")
    parser.add_argument("--output", type=Path, help="Also write the report to this path")
    args = parser.parse_args(argv)

    if not args.discover and not args.functions:
        parser.error("pass --discover or --functions")

    bench = Benchmarker(region=args.region)

    if args.discover:
        discovered = bench.discover(args.name_filter)
        if not discovered:
            print(f"No functions matching '{args.name_filter}' found.", file=sys.stderr)
            return 1
        names = [f["FunctionName"] for f in discovered]
        print(f"Discovered {len(names)} benchmark function(s).")
    else:
        names = args.functions

    print(f"Running {args.samples} forced cold starts per function.\n")
    started = time.time()

    results = [
        bench.run(name, args.samples, cleanup=not args.no_cleanup, verbose=args.format == "table")
        for name in names
    ]

    elapsed = time.time() - started

    if args.format == "json":
        report = json.dumps(
            {
                "generated_at": datetime.now(timezone.utc).isoformat(),
                "samples_per_function": args.samples,
                "elapsed_seconds": round(elapsed, 1),
                "results": [
                    {
                        "function_name": r.function_name,
                        "runtime": r.runtime,
                        "memory_mb": r.memory_mb,
                        "architecture": r.architecture,
                        "package_bytes": r.package_bytes,
                        "cold_start_count": r.cold_start_count,
                        "init_ms": r.stats(),
                        "warm_duration_p50_ms": r.warm_duration_p50,
                        "errors": r.errors,
                    }
                    for r in results
                ],
            },
            indent=2,
        )
    elif args.format == "markdown":
        report = render_markdown(results, args.samples)
    else:
        report = render_table(results)

    print(report)
    print(f"  Completed in {elapsed:.0f}s")

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(report, encoding="utf-8")
        print(f"  Written to {args.output}")

    return 0 if any(r.cold_start_count > 0 for r in results) else 1


if __name__ == "__main__":
    sys.exit(main())
