#!/usr/bin/env python3
"""Convert macOS PF/dummynet output into a privacy-safe CI artifact."""

import argparse
import json
import re
from pathlib import Path


PIPE_HEADER = re.compile(r"^\s*0*(\d+):")
COUNTER_ROW = re.compile(r"^\s*\d+\s+udp\s+.*?\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$")
EXPECTED_RULES = {
    "dummynet out quick inet proto udp from any port 17882:17981 to any pipe 591",
    "dummynet out quick inet proto udp from any to any port 17882:17981 pipe 592",
}


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--rules", required=True, type=Path)
    parser.add_argument("--counters", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()

    rules = {line.strip() for line in args.rules.read_text(encoding="utf-8").splitlines()}
    if not EXPECTED_RULES.issubset(rules):
        raise ValueError("PF did not report both expected loopback dummynet rules")

    pipes: dict[int, dict[str, int | bool]] = {}
    current_pipe: int | None = None
    for line in args.counters.read_text(encoding="utf-8").splitlines():
        header = PIPE_HEADER.match(line)
        if header:
            current_pipe = int(header.group(1))
            pipes.setdefault(current_pipe, {"present": True, "packets": 0, "bytes": 0, "drops": 0})
            continue
        row = COUNTER_ROW.match(line)
        if row and current_pipe in (591, 592):
            packets, byte_count, _queued_packets, _queued_bytes, drops = map(int, row.groups())
            pipe = pipes[current_pipe]
            pipe["packets"] = int(pipe["packets"]) + packets
            pipe["bytes"] = int(pipe["bytes"]) + byte_count
            pipe["drops"] = int(pipe["drops"]) + drops

    observed_packets = sum(int(pipes.get(pipe, {}).get("packets", 0)) for pipe in (591, 592))
    observed_drops = sum(int(pipes.get(pipe, {}).get("drops", 0)) for pipe in (591, 592))
    if any(int(pipes.get(pipe, {}).get("packets", 0)) <= 0 for pipe in (591, 592)):
        raise ValueError("dummynet did not observe media traffic in both directions")
    if observed_packets <= 0:
        raise ValueError("dummynet reported no classified media packets")
    if observed_drops <= 0:
        raise ValueError("dummynet reported no dropped media packets at the configured loss rate")

    report = {
        "schemaVersion": 1,
        "classification": "synthetic-ci-network-conditioner",
        "commit": args.commit,
        "runID": args.run_id,
        "configured": {
            "interface": "lo0",
            "udpPortRange": "17882-17981",
            "directionalBandwidthKbitPerSecond": 20_000,
            "delaySequenceMilliseconds": [20, 60, 30, 50],
            "packetLossProbabilityPercent": 0.5,
        },
        "observed": {
            "packets": observed_packets,
            "bytes": sum(int(pipes.get(pipe, {}).get("bytes", 0)) for pipe in (591, 592)),
            "droppedPackets": observed_drops,
            "pipes": {str(pipe): pipes.get(pipe, {"present": False, "packets": 0, "bytes": 0, "drops": 0}) for pipe in (591, 592)},
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    print(f"Dummynet conditioned {observed_packets} UDP packets and dropped {observed_drops}.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        raise SystemExit(f"invalid network-conditioner evidence: {error}")
