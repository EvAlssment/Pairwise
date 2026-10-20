#!/usr/bin/env python3
"""Validate the deliberately metadata-only synthetic media benchmark artifact."""

import json
import sys
from pathlib import Path


ALLOWED_FIELDS = {
    "schemaVersion",
    "classification",
    "networkProfile",
    "configuredNetwork",
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
    "packetLossPercent",
    "selectedPathRTTMilliseconds",
    "unmeasured",
}
ALWAYS_UNMEASURED = {
    "pointer_to_render_latency",
    "sender_cpu",
    "receiver_cpu",
    "readability",
}
MEASUREMENTS = {
    "packetLossPercent": (0, 100),
    "selectedPathRTTMilliseconds": (0, 120_000),
}


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: validate-media-benchmark.py REPORT-2p.json REPORT-4p.json", file=sys.stderr)
        return 2
    observed_profiles = set()
    commits = set()
    run_ids = set()
    network_profiles = set()
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
        if report["schemaVersion"] != 2:
            raise ValueError(f"{name}: unexpected benchmark schema or classification")
        profile = report["networkProfile"]
        if profile not in ("baseline", "constrained"):
            raise ValueError(f"{name}: unsupported network profile")
        if report["classification"] != f"synthetic-{profile}-ci":
            raise ValueError(f"{name}: classification does not match network profile")
        configured = report["configuredNetwork"]
        if not isinstance(configured, dict) or set(configured) != {
            "directionalBandwidthKbitPerSecond",
            "oneWayDelayMilliseconds",
            "delayVariationMilliseconds",
            "packetLossProbabilityPercent",
        }:
            raise ValueError(f"{name}: malformed network-condition metadata")
        if profile == "baseline":
            expected_config = {
                "directionalBandwidthKbitPerSecond": 0,
                "oneWayDelayMilliseconds": 0,
                "delayVariationMilliseconds": [0],
                "packetLossProbabilityPercent": 0,
            }
        else:
            expected_config = {
                "directionalBandwidthKbitPerSecond": 20_000,
                "oneWayDelayMilliseconds": 40,
                "delayVariationMilliseconds": [20, 60, 30, 50],
                "packetLossProbabilityPercent": 0.5,
            }
        if configured != expected_config:
            raise ValueError(f"{name}: network-condition metadata does not match the defined profile")
        network_profiles.add(profile)
        if not isinstance(report["commit"], str) or not report["commit"]:
            raise ValueError(f"{name}: commit SHA is required")
        if not isinstance(report["runID"], str) or not report["runID"]:
            raise ValueError(f"{name}: workflow run ID is required")
        commits.add(report["commit"])
        run_ids.add(report["runID"])
        participants = report["participantCount"]
        if report["source"] != "synthetic-screen-track" or participants not in (2, 4):
            raise ValueError(f"{name}: unexpected benchmark source or participant profile")
        observed_profiles.add((profile, participants))
        if report["framesReceived"] <= 0:
            raise ValueError(f"{name}: benchmark did not receive video frames")
        unmeasured = report["unmeasured"]
        if not isinstance(unmeasured, list) or len(unmeasured) != len(set(unmeasured)):
            raise ValueError(f"{name}: unmeasured fields must be a unique list")
        if set(unmeasured) != ALWAYS_UNMEASURED:
            raise ValueError(f"{name}: pointer latency, CPU, and readability must remain explicitly unmeasured")
        for field, (minimum, maximum) in MEASUREMENTS.items():
            value = report.get(field)
            if not isinstance(value, (int, float)) or not minimum <= value <= maximum:
                raise ValueError(f"{name}: missing or invalid measured field: {field}")
        if profile == "constrained" and report["selectedPathRTTMilliseconds"] < 20:
            raise ValueError(f"{name}: constrained profile did not measurably increase selected-path RTT")
        for field in ("width", "height", "observedFramesPerSecond", "timeToFirstFrameMilliseconds"):
            if not isinstance(report.get(field), (int, float)) or report[field] <= 0:
                raise ValueError(f"{name}: missing or invalid measured field: {field}")
        recovery = report.get("syntheticSenderPauseRecoveryMilliseconds")
        if not isinstance(recovery, (int, float)) or recovery <= 0:
            raise ValueError(f"{name}: missing or invalid sender-pause recovery measurement")
        print(
            f"{profile} {participants}p: selected RTT {report['selectedPathRTTMilliseconds']:.1f} ms, "
            f"packet loss {report['packetLossPercent']:.2f}%, "
            f"observed FPS {report['observedFramesPerSecond']:.1f}"
        )
    if observed_profiles != {("baseline", 2), ("baseline", 4), ("constrained", 2), ("constrained", 4)}:
        raise ValueError("benchmark artifacts must include baseline and constrained 2-person/4-person profiles")
    if network_profiles != {"baseline", "constrained"}:
        raise ValueError("benchmark artifacts must include both network conditions")
    if len(commits) != 1 or len(run_ids) != 1:
        raise ValueError("benchmark profiles must come from the same commit and workflow run")
    print("All four synthetic baseline/constrained benchmark profiles passed schema, network, and privacy validation.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"invalid synthetic benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
