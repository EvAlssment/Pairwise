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
    if len(sys.argv) < 2:
        print("usage: validate-media-benchmark.py REPORT-2p.json REPORT-4p.json", file=sys.stderr)
        return 2
    observed_profiles = set()
    commits = set()
    run_ids = set()
    for name in sys.argv[1:]:
        report = json.loads(Path(name).read_text(encoding="utf-8"))
        if not isinstance(report, dict) or not set(report).issubset(ALLOWED_FIELDS):
            raise ValueError(f"{name}: benchmark contains an unknown field")
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
            raise ValueError(f"{name}: benchmark is missing a required field")
        if report["schemaVersion"] != 1 or report["classification"] != "synthetic-loopback-ci":
            raise ValueError(f"{name}: unexpected benchmark schema or classification")
        if not isinstance(report["commit"], str) or not report["commit"]:
            raise ValueError(f"{name}: commit SHA is required")
        if not isinstance(report["runID"], str) or not report["runID"]:
            raise ValueError(f"{name}: workflow run ID is required")
        commits.add(report["commit"])
        run_ids.add(report["runID"])
        profile = report["participantCount"]
        if report["source"] != "synthetic-screen-track" or profile not in (2, 4):
            raise ValueError(f"{name}: unexpected benchmark source or participant profile")
        observed_profiles.add(profile)
        if report["framesReceived"] <= 0:
            raise ValueError(f"{name}: benchmark did not receive video frames")
        if set(report["unmeasured"]) != UNMEASURED:
            raise ValueError(f"{name}: unmeasured fields must remain explicit")
        for field in ("width", "height", "observedFramesPerSecond", "timeToFirstFrameMilliseconds"):
            if not isinstance(report.get(field), (int, float)) or report[field] <= 0:
                raise ValueError(f"{name}: missing or invalid measured field: {field}")
        recovery = report.get("syntheticSenderPauseRecoveryMilliseconds")
        if not isinstance(recovery, (int, float)) or recovery <= 0:
            raise ValueError(f"{name}: missing or invalid sender-pause recovery measurement")
    if observed_profiles != {2, 4}:
        raise ValueError("benchmark artifacts must include both 2-person and 4-person profiles")
    if len(commits) != 1 or len(run_ids) != 1:
        raise ValueError("benchmark profiles must come from the same commit and workflow run")
    print("Both synthetic benchmark profiles passed schema and privacy allowlist validation.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"invalid synthetic benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
