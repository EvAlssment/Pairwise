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
            "directionalBandwidthKbitPerSecond": 20_000 if constrained else 0,
            "oneWayDelayMilliseconds": 40 if constrained else 0,
            "delayVariationMilliseconds": [20, 60, 30, 50] if constrained else [0],
            "packetLossProbabilityPercent": 0.5 if constrained else 0,
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
        "unmeasured": ["pointer_to_render_latency", "sender_cpu", "receiver_cpu", "readability"],
    }


class MediaBenchmarkValidatorTests(unittest.TestCase):
    def run_validator(self, zero_bitrate: bool = False) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory(prefix="pairwise-benchmark-validator-") as temporary:
            reports = []
            for profile in ("baseline", "constrained"):
                for participants in (2, 4):
                    report = benchmark(profile, participants)
                    if zero_bitrate:
                        report["receivedBitrateKilobitsPerSecond"] = 0
                    path = Path(temporary) / f"{profile}-{participants}p.json"
                    path.write_text(json.dumps(report), encoding="utf-8")
                    reports.append(str(path))
            return subprocess.run(
                [sys.executable, str(VALIDATOR), *reports],
                check=False,
                capture_output=True,
                text=True,
            )

    def test_accepts_complete_baseline_and_constrained_profiles(self) -> None:
        result = self.run_validator()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("received bitrate 850 kbit/s", result.stdout)

    def test_rejects_unmeasured_zero_bitrate(self) -> None:
        result = self.run_validator(zero_bitrate=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("received bitrate must be a positive measured value", result.stderr)


if __name__ == "__main__":
    unittest.main()
