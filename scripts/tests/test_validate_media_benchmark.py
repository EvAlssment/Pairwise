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
        "schemaVersion": 5,
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
        "syntheticReadability": {
            "recognizedLines": 3,
            "totalLines": 4,
            "recognizedTextPercent": 75.0,
            "testedFontSizesPixels": [12, 16, 20, 24],
            "recognizedFontSizesPixels": [16, 20, 24],
            "smallestRecognizedFontPixels": 16,
            "measurement": "Vision OCR of a transient synthetic decoded frame; recognized text is not stored",
        },
        "runner": {
            "platform": "macOS",
            "osVersion": "15.6.1",
            "architecture": "arm64",
            "modelIdentifier": "Mac14,5",
            "logicalCPUCount": 8,
        },
        "unmeasured": ["pointer_to_render_latency", "sender_cpu", "receiver_cpu", "physical_readability"],
    }


def cursor_benchmark(profile: str, participants: int) -> dict:
    return {
        "schemaVersion": 2,
        "classification": "synthetic-local-cursor-ci",
        "networkProfile": profile,
        "commit": "test-commit",
        "runID": "test-run",
        "generatedAt": "2026-10-20T00:00:00Z",
        "participantCount": participants,
        "sampleCount": 30,
        "p50PublishToOverlayRenderMilliseconds": 4.0,
        "p95PublishToOverlayRenderMilliseconds": 12.0,
        "runner": {
            "platform": "macOS",
            "osVersion": "15.6.1",
            "architecture": "arm64",
            "modelIdentifier": "Mac14,5",
            "logicalCPUCount": 8,
        },
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
        malformed_readability: bool = False,
        zero_drops: bool = False,
        negative_rtt: bool = False,
        missing_outbound_traffic: bool = False,
        missing_runner_metadata: bool = False,
        mismatched_runner_metadata: bool = False,
    ) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="pairwise-benchmark-validator-") as temporary:
            reports = []
            for profile in ("baseline", "constrained"):
                for participants in (2, 4):
                    report = benchmark(profile, participants)
                    if zero_bitrate:
                        report["receivedBitrateKilobitsPerSecond"] = 0
                    if malformed_readability:
                        report["syntheticReadability"]["recognizedTextPercent"] = 100.0
                    if negative_rtt and profile == "baseline" and participants == 2:
                        report["selectedPathRTTMilliseconds"] = -1
                    if missing_runner_metadata and profile == "baseline" and participants == 2:
                        report["runner"] = {}
                    if mismatched_runner_metadata and profile == "constrained" and participants == 2:
                        report["runner"]["architecture"] = "x86_64"
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
        self.assertIn("synthetic OCR 3/4 lines", result.stdout)
        self.assertIn("dummynet: 693 packets, 166721 bytes, 3 dropped", result.stdout)

    def test_cursor_latency_is_reported_with_explicit_loopback_limits(self) -> None:
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("baseline 2p cursor: p50 4.0 ms, p95 12.0 ms", result.stdout)

    def test_rejects_unmeasured_zero_bitrate(self) -> None:
        result = self.run_validator(zero_bitrate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("received bitrate must be a positive measured value", result.stderr)

    def test_rejects_inconsistent_synthetic_readability_percentage(self) -> None:
        result = self.run_validator(malformed_readability=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("percentage does not match recognized line count", result.stderr)

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

    def test_rejects_benchmark_without_runner_metadata(self) -> None:
        result = self.run_validator(missing_runner_metadata=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("runner metadata contains unknown or missing fields", result.stderr)

    def test_rejects_profiles_from_different_runners(self) -> None:
        result = self.run_validator(mismatched_runner_metadata=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("profiles must come from the same CI runner", result.stderr)


if __name__ == "__main__":
    unittest.main()
