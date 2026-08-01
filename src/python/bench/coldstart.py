"""Cold-start benchmark subject -- Python 3.12.

Mirrors src/nodejs/src/bench/coldstart.js as closely as the language allows so
the runtime comparison is apples-to-apples: no third-party imports, the same
shape of module-scope init work, the same JSON log line.
"""

import json
import os
import sys
import time

_INIT_STARTED_AT = time.monotonic()

RUNTIME = f"python{sys.version_info.major}.{sys.version_info.minor}"

CONFIG = {
    "region": os.environ.get("AWS_REGION"),
    "memory_mb": int(os.environ.get("AWS_LAMBDA_FUNCTION_MEMORY_SIZE", "0")),
    "version": os.environ.get("AWS_LAMBDA_FUNCTION_VERSION"),
    # BENCH_NONCE is bumped by the harness to force a new execution environment.
    "nonce": os.environ.get("BENCH_NONCE", "none"),
}

_INIT_DURATION_MS = round((time.monotonic() - _INIT_STARTED_AT) * 1000, 3)
_invocation_count = 0


def handler(event, context):
    global _invocation_count
    _invocation_count += 1
    is_cold_start = _invocation_count == 1

    print(
        json.dumps(
            {
                "level": "INFO",
                "message": "bench_invocation",
                "runtime": RUNTIME,
                "coldStart": is_cold_start,
                "moduleInitMs": _INIT_DURATION_MS,
                "memoryMb": CONFIG["memory_mb"],
                "nonce": CONFIG["nonce"],
                "requestId": getattr(context, "aws_request_id", None),
            }
        )
    )

    return {
        "runtime": RUNTIME,
        "coldStart": is_cold_start,
        "moduleInitMs": _INIT_DURATION_MS,
        "memoryMb": CONFIG["memory_mb"],
        "invocationCount": _invocation_count,
        "echo": (event or {}).get("ping"),
    }
