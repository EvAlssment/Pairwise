#!/usr/bin/env python3
"""Validate the deliberately metadata-only synthetic media benchmark artifact."""

import json
import sys
import argparse
import math
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
    "receivedBitrateKilobitsPerSecond",
    "framesReceived",
    "timeToFirstFrameMilliseconds",
    "syntheticSenderPauseRecoveryMilliseconds",
    "packetLossPercent",
    "selectedPathRTTMilliseconds",
    "harnessProcessCPUPercent",
    "unmeasured",
}
ALWAYS_UNMEASURED = {
    "pointer_to_render_latency",
    "sender_cpu",
    "receiver_cpu",
    "readability",
}
MEASUREMENTS = {
    "receivedBitrateKilobitsPerSecond": (0, 100_000),
    "packetLossPercent": (0, 100),
    "selectedPathRTTMilliseconds": (0, 120_000),
    "harnessProcessCPUPercent": (0, 2_000),
}
CURSOR_FIELDS = {
    "schemaVersion",
    "classification",
    "networkProfile",
    "commit",
    "runID",
    "generatedAt",
    "participantCount",
    "sampleCount",
    "p50PublishToOverlayRenderMilliseconds",
    "p95PublishToOverlayRenderMilliseconds",
    "measurement",
    "limitations",
}
CURSOR_LIMITATIONS = [
    "single-host LiveKit loopback",
    "no physical display scanout",
    "not a cross-region one-way latency",
]


def finite_number(value: object) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("reports", nargs="+")
    parser.add_argument("--cursor-reports", nargs="+", required=True)
    parser.add_argument("--conditioner")
    args = parser.parse_args()
    observed_profiles = set()
    commits = set()
    run_ids = set()
    network_profiles = set()
    for name in args.reports:
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
        if report["schemaVersion"] != 3:
            raise ValueError(f"{name}: unexpected benchmark schema or classification")
        profile = report["networkProfile"]
        if profile not in ("baseline", "constrained"):
            raise ValueError(f"{name}: unsupported network profile")
        if report["classification"] != f"synthetic-{profile}-ci":
            raise ValueError(f"{name}: classification does not match network profile")
        configured = report["configuredNetwork"]
        if not isinstance(configured, dict) or set(configured) != {
            "outboundBandwidthKbitPerSecond",
            "outboundOneWayDelayMilliseconds",
            "outboundDelayVariationMilliseconds",
            "outboundPacketLossProbabilityPercent",
        }:
            raise ValueError(f"{name}: malformed network-condition metadata")
        if profile == "baseline":
            expected_config = {
                "outboundBandwidthKbitPerSecond": 0,
                "outboundOneWayDelayMilliseconds": 0,
                "outboundDelayVariationMilliseconds": [0],
                "outboundPacketLossProbabilityPercent": 0,
            }
        else:
            expected_config = {
                "outboundBandwidthKbitPerSecond": 20_000,
                "outboundOneWayDelayMilliseconds": 40,
                "outboundDelayVariationMilliseconds": [20, 60, 30, 50],
                "outboundPacketLossProbabilityPercent": 1.0,
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
        if report["source"] != "synthetic-screen-track" or type(participants) is not int or participants not in (2, 4):
            raise ValueError(f"{name}: unexpected benchmark source or participant profile")
        observed_profiles.add((profile, participants))
        if type(report["framesReceived"]) is not int or report["framesReceived"] <= 0:
            raise ValueError(f"{name}: benchmark did not receive video frames")
        unmeasured = report["unmeasured"]
        if not isinstance(unmeasured, list) or len(unmeasured) != len(set(unmeasured)):
            raise ValueError(f"{name}: unmeasured fields must be a unique list")
        if set(unmeasured) != ALWAYS_UNMEASURED:
            raise ValueError(f"{name}: pointer latency, CPU, and readability must remain explicitly unmeasured")
        for field, (minimum, maximum) in MEASUREMENTS.items():
            value = report.get(field)
            if (
                not finite_number(value)
                or not minimum <= value <= maximum
            ):
                raise ValueError(f"{name}: missing or invalid measured field: {field}")
        if report["receivedBitrateKilobitsPerSecond"] <= 0:
            raise ValueError(f"{name}: received bitrate must be a positive measured value")
        if profile == "constrained" and report["selectedPathRTTMilliseconds"] < 20:
            raise ValueError(f"{name}: constrained profile did not measurably increase selected-path RTT")
        for field in ("width", "height", "observedFramesPerSecond", "timeToFirstFrameMilliseconds"):
            if not finite_number(report.get(field)) or report[field] <= 0:
                raise ValueError(f"{name}: missing or invalid measured field: {field}")
        recovery = report.get("syntheticSenderPauseRecoveryMilliseconds")
        if not finite_number(recovery) or recovery <= 0:
            raise ValueError(f"{name}: missing or invalid sender-pause recovery measurement")
        print(
            f"{profile} {participants}p: selected RTT {report['selectedPathRTTMilliseconds']:.1f} ms, "
            f"packet loss {report['packetLossPercent']:.2f}%, "
            f"observed FPS {report['observedFramesPerSecond']:.1f}, "
            f"received bitrate {report['receivedBitrateKilobitsPerSecond']:.0f} kbit/s"
        )
    if observed_profiles != {("baseline", 2), ("baseline", 4), ("constrained", 2), ("constrained", 4)}:
        raise ValueError("benchmark artifacts must include baseline and constrained 2-person/4-person profiles")
    if network_profiles != {"baseline", "constrained"}:
        raise ValueError("benchmark artifacts must include both network conditions")
    if len(commits) != 1 or len(run_ids) != 1:
        raise ValueError("benchmark profiles must come from the same commit and workflow run")
    cursor_profiles = set()
    for name in args.cursor_reports:
        report = json.loads(Path(name).read_text(encoding="utf-8"))
        if not isinstance(report, dict) or set(report) != CURSOR_FIELDS:
            raise ValueError(f"{name}: cursor benchmark contains unknown or missing fields")
        if report["schemaVersion"] != 1 or report["classification"] != "synthetic-local-cursor-ci":
            raise ValueError(f"{name}: unexpected cursor benchmark schema or classification")
        profile = report["networkProfile"]
        participants = report["participantCount"]
        if profile not in ("baseline", "constrained") or type(participants) is not int or participants not in (2, 3):
            raise ValueError(f"{name}: unsupported cursor benchmark profile")
        cursor_profiles.add((profile, participants))
        if not isinstance(report["commit"], str) or not report["commit"]:
            raise ValueError(f"{name}: commit SHA is required")
        if not isinstance(report["runID"], str) or not report["runID"]:
            raise ValueError(f"{name}: workflow run ID is required")
        commits.add(report["commit"])
        run_ids.add(report["runID"])
        if type(report["sampleCount"]) is not int or report["sampleCount"] < 30:
            raise ValueError(f"{name}: at least 30 cursor samples are required")
        p50 = report["p50PublishToOverlayRenderMilliseconds"]
        p95 = report["p95PublishToOverlayRenderMilliseconds"]
        if not finite_number(p50) or not 0 <= p50 <= 6_000:
            raise ValueError(f"{name}: invalid p50 cursor render latency")
        if not finite_number(p95) or not p50 <= p95 <= 6_000:
            raise ValueError(f"{name}: invalid p95 cursor render latency")
        if report["measurement"] != "sender publish call to the sharer's native overlay view render pass":
            raise ValueError(f"{name}: unexpected cursor latency measurement boundary")
        if report["limitations"] != CURSOR_LIMITATIONS:
            raise ValueError(f"{name}: cursor benchmark limitations must remain explicit")
        print(f"{profile} {participants}p cursor: p50 {p50:.1f} ms, p95 {p95:.1f} ms (synthetic loopback)")
    if cursor_profiles != {("baseline", 2), ("baseline", 3), ("constrained", 2), ("constrained", 3)}:
        raise ValueError("cursor artifacts must include baseline and constrained 2-person/3-person profiles")
    if len(commits) != 1 or len(run_ids) != 1:
        raise ValueError("media and cursor profiles must come from the same commit and workflow run")
    if args.conditioner:
        conditioner_path = Path(args.conditioner)
        conditioner = json.loads(conditioner_path.read_text(encoding="utf-8"))
        if not isinstance(conditioner, dict) or set(conditioner) != {
            "schemaVersion", "classification", "commit", "runID", "configured", "observed"
        }:
            raise ValueError("network-conditioner artifact contains unknown or missing fields")
        if conditioner["schemaVersion"] != 1 or conditioner["classification"] != "synthetic-ci-network-conditioner":
            raise ValueError("unexpected network-conditioner schema or classification")
        if conditioner["commit"] not in commits or conditioner["runID"] not in run_ids:
            raise ValueError("network-conditioner evidence must match the benchmark commit and workflow run")
        configured = conditioner["configured"]
        if not isinstance(configured, dict) or configured != {
            "interface": "all",
            "direction": "client-to-livekit-server",
            "udpPortRange": "17882-17981",
            "outboundBandwidthKbitPerSecond": 20_000,
            "delaySequenceMilliseconds": [20, 60, 30, 50],
            "packetLossProbabilityPercent": 1.0,
        }:
            raise ValueError("network-conditioner configuration does not match the constrained profile")
        observed = conditioner["observed"]
        if not isinstance(observed, dict) or set(observed) != {"packets", "bytes", "droppedPackets", "pipes"}:
            raise ValueError("malformed network-conditioner observations")
        if not isinstance(observed["packets"], int) or observed["packets"] <= 0:
            raise ValueError("network conditioner did not classify media packets")
        if not isinstance(observed["bytes"], int) or observed["bytes"] <= 0:
            raise ValueError("network conditioner did not account for media bytes")
        if not isinstance(observed["droppedPackets"], int) or observed["droppedPackets"] <= 0:
            raise ValueError("network conditioner did not observe packet drops")
        pipes = observed["pipes"]
        if not isinstance(pipes, dict) or set(pipes) != {"592"}:
            raise ValueError("network-conditioner artifact must include measured outbound pipe 592")
        for pipe_id, pipe in pipes.items():
            if not isinstance(pipe, dict) or set(pipe) != {"present", "packets", "bytes", "drops"}:
                raise ValueError(f"pipe {pipe_id}: malformed counters")
            if not isinstance(pipe["present"], bool) or any(
                not isinstance(pipe[field], int) or pipe[field] < 0 for field in ("packets", "bytes", "drops")
            ):
                raise ValueError(f"pipe {pipe_id}: invalid counters")
            if not pipe["present"] or pipe["packets"] <= 0 or pipe["bytes"] <= 0:
                raise ValueError(f"pipe {pipe_id}: missing outbound traffic evidence")
        if sum(pipe["packets"] for pipe in pipes.values()) != observed["packets"]:
            raise ValueError("network-conditioner packet total does not match outbound counters")
        if sum(pipe["bytes"] for pipe in pipes.values()) != observed["bytes"]:
            raise ValueError("network-conditioner byte total does not match outbound counters")
        if sum(pipe["drops"] for pipe in pipes.values()) != observed["droppedPackets"]:
            raise ValueError("network-conditioner drop total does not match outbound counters")
        print(
            f"dummynet: {observed['packets']} packets, {observed['bytes']} bytes, "
            f"{observed['droppedPackets']} dropped on client-to-LiveKit outbound traffic"
        )
    print("Synthetic screen and cursor profiles passed schema, network, and privacy validation.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"invalid synthetic benchmark: {error}", file=sys.stderr)
        raise SystemExit(1)
