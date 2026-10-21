#!/usr/bin/env python3
"""Regression checks for the strict metadata-only media benchmark validator."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


VALIDATOR = Path(__file__).resolve().parents[1] / "validate-media-benchmark.py"


def benchmark(profile: str, participants: int) -> dict:
    constrained = profile == "constrained"
    return {
        "schemaVersion": 3,
        "classification": f"synthetic-{profile}-ci",
        "networkProfile": profile,
        "configuredNetwork": {
            "outboundBandwidthKbitPerSecond": 20_000 if constrained else 0,
            "outboundOneWayDelayMilliseconds": 40 if constrained else 0,
            "outboundDelayVariationMilliseconds": [20, 60, 30, 50] if constrained else [0],
            "outboundPacketLossProbabilityPercent": 1.0 if constrained else 0,
        },
        "commit": "test-commit",
        "runID": "test-run",
        "generatedAt": "2026-10-20T00:00:00Z",
        "participantCount": participants,
        "source": "synthetic-screen-track",
        "width": 1920,
        "height": 1080,
        "observedFramesPerSecond": 30.0,
        "receivedBitrateKilobitsPerSecond": 850.0,
        "framesReceived": 90,
        "timeToFirstFrameMilliseconds": 120.0,
        "syntheticSenderPauseRecoveryMilliseconds": 35.0,
        "packetLossPercent": 0.0,
        "selectedPathRTTMilliseconds": 40.0 if constrained else 2.0,
        "harnessProcessCPUPercent": 65.0,
        "unmeasured": ["pointer_to_render_latency", "sender_cpu", "receiver_cpu", "readability"],
    }


def cursor_benchmark(profile: str, participants: int) -> dict:
    return {
        "schemaVersion": 1,
        "classification": "synthetic-local-cursor-ci",
        "networkProfile": profile,
        "commit": "test-commit",
        "runID": "test-run",
        "generatedAt": "2026-10-20T00:00:00Z",
        "participantCount": participants,
        "sampleCount": 30,
        "p50PublishToOverlayRenderMilliseconds": 4.0,
        "p95PublishToOverlayRenderMilliseconds": 12.0,
        "measurement": "sender publish call to the sharer's native overlay view render pass",
        "limitations": [
            "single-host LiveKit loopback",
            "no physical display scanout",
            "not a cross-region one-way latency",
        ],
    }


def conditioner() -> dict:
    return {
        "schemaVersion": 1,
        "classification": "synthetic-ci-network-conditioner",
        "commit": "test-commit",
        "runID": "test-run",
        "configured": {
            "interface": "all",
            "direction": "client-to-livekit-server",
            "udpPortRange": "17882-17981",
            "outboundBandwidthKbitPerSecond": 20_000,
            "delaySequenceMilliseconds": [20, 60, 30, 50],
            "packetLossProbabilityPercent": 1.0,
        },
        "observed": {
            "packets": 693,
            "bytes": 166_721,
            "droppedPackets": 3,
            "pipes": {
                "592": {"present": True, "packets": 693, "bytes": 166_721, "drops": 3},
            },
        },
    }


class MediaBenchmarkValidatorTests(unittest.TestCase):
    def run_validator(
        self,
        zero_bitrate: bool = False,
        zero_drops: bool = False,
        negative_rtt: bool = False,
        missing_outbound_traffic: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="pairwise-benchmark-validator-") as temporary:
            reports = []
            for profile in ("baseline", "constrained"):
                for participants in (2, 4):
                    report = benchmark(profile, participants)
                    if zero_bitrate:
                        report["receivedBitrateKilobitsPerSecond"] = 0
                    if negative_rtt and profile == "baseline" and participants == 2:
                        report["selectedPathRTTMilliseconds"] = -1
                    path = Path(temporary) / f"{profile}-{participants}p.json"
                    path.write_text(json.dumps(report), encoding="utf-8")
                    reports.append(str(path))
            conditioner_path = Path(temporary) / "network-conditioner.json"
            conditioner_report = conditioner()
            if zero_drops:
                conditioner_report["observed"]["droppedPackets"] = 0
                conditioner_report["observed"]["pipes"]["592"]["drops"] = 0
            if missing_outbound_traffic:
                conditioner_report["observed"]["packets"] = 0
                conditioner_report["observed"]["bytes"] = 0
                conditioner_report["observed"]["droppedPackets"] = 0
                conditioner_report["observed"]["pipes"]["592"] = {
                    "present": False, "packets": 0, "bytes": 0, "drops": 0,
                }
            conditioner_path.write_text(json.dumps(conditioner_report), encoding="utf-8")
            cursor_reports = []
            for profile in ("baseline", "constrained"):
                for participants in (2, 3):
                    path = Path(temporary) / f"cursor-{profile}-{participants}p.json"
                    path.write_text(json.dumps(cursor_benchmark(profile, participants)), encoding="utf-8")
                    cursor_reports.append(str(path))
            return subprocess.run(
                [sys.executable, str(VALIDATOR), *reports, "--cursor-reports", *cursor_reports,
                 "--conditioner", str(conditioner_path)],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_complete_baseline_and_constrained_profiles(self) -> None:
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("received bitrate 850 kbit/s", result.stdout)
        self.assertIn("dummynet: 693 packets, 166721 bytes, 3 dropped", result.stdout)

    def test_cursor_latency_is_reported_with_explicit_loopback_limits(self) -> None:
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("baseline 2p cursor: p50 4.0 ms, p95 12.0 ms", result.stdout)

    def test_rejects_unmeasured_zero_bitrate(self) -> None:
        result = self.run_validator(zero_bitrate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("received bitrate must be a positive measured value", result.stderr)

    def test_rejects_conditioner_without_observed_packet_drops(self) -> None:
        result = self.run_validator(zero_drops=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not observe packet drops", result.stderr)

    def test_rejects_conditioner_without_observed_outbound_traffic(self) -> None:
        result = self.run_validator(missing_outbound_traffic=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("did not classify media packets", result.stderr)

    def test_rejects_negative_measurements(self) -> None:
        result = self.run_validator(negative_rtt=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or invalid measured field: selectedPathRTTMilliseconds", result.stderr)


if __name__ == "__main__":
    unittest.main()
