#!/usr/bin/env python3
"""Regression checks for parsing macOS dummynet counters without host data."""

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


WRITER = Path(__file__).resolve().parents[1] / "write-network-condition-report.py"


class NetworkConditionReportTests(unittest.TestCase):
    def run_writer(self, rows: str):
        temporary = tempfile.TemporaryDirectory(prefix="pairwise-dummynet-report-")
        root = Path(temporary.name)
        rules = root / "rules.txt"
        counters = root / "counters.txt"
        output = root / "network-conditioner.json"
        rules.write_text(
            "dummynet in quick on lo0 inet proto udp from any port 17882:17981 to any pipe 591\n"
            "dummynet out quick on lo0 inet proto udp from any to any port 17882:17981 pipe 592\n",
            encoding="utf-8",
        )
        counters.write_text(rows, encoding="utf-8")
        result = subprocess.run(
            [
                sys.executable, str(WRITER), "--rules", str(rules), "--counters", str(counters),
                "--output", str(output), "--commit", "abc123", "--run-id", "42",
            ],
            check=False, capture_output=True, text=True,
        )
        return result, output, temporary

    def test_emits_only_aggregate_directional_counters(self) -> None:
        result, output, temporary = self.run_writer(
            "00591: 20.000 Mbit/s 30 ms 50 sl.plr 0.005000 1 queues (1 buckets) droptail\n"
            "BKT Prot ___Source IP/port____ ____Dest. IP/port____ Tot_pkt/bytes Pkt/Byte Drp\n"
            "  0 udp 192.0.2.1/17882 192.0.2.1/63931 420 100321 0 0 1\n"
            "00592: 20.000 Mbit/s 30 ms 50 sl.plr 0.005000 1 queues (1 buckets) droptail\n"
            "BKT Prot ___Source IP/port____ ____Dest. IP/port____ Tot_pkt/bytes Pkt/Byte Drp\n"
            "  0 udp 192.0.2.1/63931 192.0.2.1/17932 693 166721 0 0 2\n"
        )
        try:
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(report["observed"]["packets"], 1_113)
            self.assertEqual(report["observed"]["bytes"], 267_042)
            self.assertEqual(report["observed"]["droppedPackets"], 3)
            self.assertEqual(report["observed"]["pipes"]["591"], {
                "present": True, "packets": 420, "bytes": 100_321, "drops": 1,
            })
            self.assertEqual(report["observed"]["pipes"]["592"], {
                "present": True, "packets": 693, "bytes": 166_721, "drops": 2,
            })
            self.assertNotIn("192.0.2.1", output.read_text(encoding="utf-8"))
        finally:
            temporary.cleanup()

    def test_rejects_one_way_traffic_even_when_drops_are_observed(self) -> None:
        result, output, temporary = self.run_writer(
            "00592: 20.000 Mbit/s 30 ms 50 sl.plr 0.005000 1 queues (1 buckets) droptail\n"
            "BKT Prot ___Source IP/port____ ____Dest. IP/port____ Tot_pkt/bytes Pkt/Byte Drp\n"
            "  0 udp 192.0.2.1/63931 192.0.2.1/17932 693 166721 0 0 2\n"
        )
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("both directions", result.stderr)
            self.assertFalse(output.exists())
        finally:
            temporary.cleanup()

    def test_rejects_empty_or_unconditioned_transport_counters(self) -> None:
        result, output, temporary = self.run_writer(
            "00592: 20.000 Mbit/s 30 ms 50 sl.plr 0.005000 1 queues (1 buckets) droptail\n"
        )
        try:
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("both directions", result.stderr)
            self.assertFalse(output.exists())
        finally:
            temporary.cleanup()


if __name__ == "__main__":
    unittest.main()
