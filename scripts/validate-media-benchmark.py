#!/usr/bin/env python3
"""Validate the deliberately metadata-only synthetic media benchmark artifact."""

import json
import sys
from pathlib import Path


ALLOWED_FIELDS = {
    "schemaVersion",
    "classification",
    "commit",
    "runID",
    "generatedAt",
    "participantCount",
    "source",
    "width",
    "height",
    "observedFramesPerSecond",
    "framesReceived",
    "timeToFirstFrameMilliseconds",
    "syntheticSenderPauseRecoveryMilliseconds",
    "unmeasured",
}
UNMEASURED = {
    "packet_loss",
    "selected_path_rtt",
    "pointer_to_render_latency",
    "sender_cpu",
    "receiver_cpu",
    "readability",
}


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: validate-media-benchmark.py REPORT.json", file=sys.stderr)
        return 2
    report = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not isinstance(report, dict) or not set(report).issubset(ALLOWED_FIELDS):
        raise ValueError("benchmark contains an unknown field")
    required = ALLOWED_FIELDS - {
        "commit",
        "runID",
        "width",
        "height",
        "observedFramesPerSecond",
        "timeToFirstFrameMilliseconds",
        "syntheticSenderPauseRecoveryMilliseconds",
    }
    if not required.issubset(report):
        raise ValueError("benchmark is missing a required field")
    if report["schemaVersion"] != 1 or report["classification"] != "synthetic-loopback-ci":
        raise ValueError("unexpected benchmark schema or classification")
    if not isinstance(report["commit"], str) or not report["commit"]:
        raise ValueError("commit SHA is required")
    if not isinstance(report["runID"], str) or not report["runID"]:
        raise ValueError("workflow run ID is required")
    if report["source"] != "synthetic-screen-track" or report["participantCount"] != 4:
        raise ValueError("unexpected benchmark source or participant profile")
    if report["framesReceived"] <= 0:
        raise ValueError("benchmark did not receive video frames")
    if set(report["unmeasured"]) != UNMEASURED:
        raise ValueError("unmeasured fields must remain explicit")
    for name in ("width", "height", "observedFramesPerSecond", "timeToFirstFrameMilliseconds"):
        if not isinstance(report.get(name), (int, float)) or report[name] <= 0:
            raise ValueError(f"missing or invalid measured field: {name}")
    recovery = report.get("syntheticSenderPauseRecoveryMilliseconds")
    if not isinstance(recovery, (int, float)) or recovery <= 0:
        raise ValueError("missing or invalid sender-pause recovery measurement")
    print("Synthetic benchmark schema and privacy allowlist passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"invalid synthetic benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
