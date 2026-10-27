#!/usr/bin/env python3
"""Compare independently produced uncached/cached process receipts and media."""
import json
from pathlib import Path
import sys


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def churn(result):
    return next(case["churn"] for case in result["cases"] if case["name"].startswith("64KiB_payload_128_updates"))


def main():
    plain_path, cached_path = map(Path, sys.argv[1:])
    plain, cached = (json.loads(path.read_text()) for path in (plain_path, cached_path))
    require(plain["passed"] and cached["passed"], "both process campaigns must pass")
    before, after = churn(plain), churn(cached)
    require(before["cache_pages"] == 0 and after["cache_pages"] in (64, 128), "wrong cache profiles")
    require(plain["snapshots"] == cached["snapshots"], "media contents changed with cache profile")
    require([case["name"] for case in plain["cases"]] == [case["name"] for case in cached["cases"]], "case sets differ")
    require(after["operation_read_bytes"] < before["operation_read_bytes"], "no measured read reduction")
    pages = after["cache_pages"]
    require(after["state_bytes"] - before["state_bytes"] == pages * (4096 + 16), "cache memory accounting mismatch")
    result = {"schema": 1, "evidence": "host-backend-read-request-comparison", "physical_transfer_or_latency_measurement": False,
              "plain_receipt": str(plain_path), "cached_receipt": str(cached_path),
              "plain_read_bytes": before["operation_read_bytes"], "cached_read_bytes": after["operation_read_bytes"],
              "read_reduction_fraction": 1 - after["operation_read_bytes"] / before["operation_read_bytes"],
              "plain_state_bytes": before["state_bytes"], "cached_state_bytes": after["state_bytes"],
              "cache_pages": pages, "cache_data_bytes": pages * 4096, "cache_tags_bytes": pages * 16,
              "all_snapshot_ranges_identical": True, "passed": True}
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
