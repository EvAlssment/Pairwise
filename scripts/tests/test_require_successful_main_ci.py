"""Regression tests for the production deployment's exact-main API-CI gate."""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


REPOSITORY = Path(__file__).resolve().parents[2]
SCRIPT = REPOSITORY / "scripts/require-successful-main-ci.sh"
COMMIT = "0123456789abcdef0123456789abcdef01234567"


class RequireSuccessfulMainCITests(unittest.TestCase):
    def run_gate(self, runs, jobs=None, commit=COMMIT):
        with tempfile.TemporaryDirectory(prefix="pairwise-main-ci-gate-") as temporary:
            bin_dir = Path(temporary) / "bin"
            bin_dir.mkdir()
            gh = bin_dir / "gh"
            gh.write_text(
                "#!/bin/sh\n"
                "if [ \"$1\" = run ] && [ \"$2\" = list ]; then\n"
                "  printf '%s' \"$PAIRWISE_FAKE_RUNS\"\n"
                "elif [ \"$1\" = run ] && [ \"$2\" = view ]; then\n"
                "  printf '%s' \"$PAIRWISE_FAKE_JOBS\"\n"
                "else exit 3; fi\n"
            )
            gh.chmod(0o755)
            environment = os.environ.copy()
            environment.update(
                PATH=f"{bin_dir}:{environment['PATH']}",
                GITHUB_REPOSITORY="EvAlssment/Pairwise",
                PAIRWISE_FAKE_RUNS=json.dumps(runs),
                PAIRWISE_FAKE_JOBS=json.dumps(jobs or {"jobs": [
                    {"name": "api-image", "status": "completed", "conclusion": "success"},
                    {"name": "postgres-integration", "status": "completed", "conclusion": "success"},
                ]}),
            )
            return subprocess.run(
                ["bash", str(SCRIPT), commit],
                env=environment,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )

    def test_accepts_successful_api_jobs_for_exact_main_push(self):
        result = self.run_gate([
            {"databaseId": 123, "event": "pull_request", "status": "completed", "conclusion": "success"},
            {"databaseId": 456, "event": "push", "status": "completed", "conclusion": "failure"},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(COMMIT, result.stdout)

    def test_rejects_pull_request_success_without_main_push_run(self):
        result = self.run_gate([
            {"databaseId": 123, "event": "pull_request", "status": "completed", "conclusion": "success"},
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("No push CI run exists", result.stderr)

    def test_rejects_in_progress_main_push_run(self):
        result = self.run_gate([
            {"databaseId": 456, "event": "push", "status": "in_progress", "conclusion": None},
        ])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("requires completed API checks", result.stderr)

    def test_allows_unrelated_macos_failure_when_api_jobs_pass(self):
        result = self.run_gate([
            {"databaseId": 456, "event": "push", "status": "completed", "conclusion": "failure"},
        ])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("API unit/race/vet, image smoke, and PostgreSQL integration", result.stdout)

    def test_rejects_failed_postgres_integration_job(self):
        result = self.run_gate(
            [{"databaseId": 456, "event": "push", "status": "completed", "conclusion": "failure"}],
            jobs={"jobs": [
                {"name": "api-image", "status": "completed", "conclusion": "success"},
                {"name": "postgres-integration", "status": "completed", "conclusion": "failure"},
            ]},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("postgres-integration", result.stderr)

    def test_rejects_malformed_commit_before_querying_github(self):
        result = self.run_gate([], commit="not-a-full-sha")
        self.assertEqual(result.returncode, 2)
        self.assertIn("FULL_40_CHARACTER_COMMIT_SHA", result.stderr)


if __name__ == "__main__":
    unittest.main()
