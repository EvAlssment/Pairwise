"""Real disk-image smoke test, using a tiny signed app instead of a full build."""
import hashlib
import importlib.util
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


@unittest.skipUnless(sys.platform == "darwin" and importlib.util.find_spec("dmgbuild"),
                     "requires macOS and scripts/dmg/requirements.txt")
class CreateDMGTests(unittest.TestCase):
    def run_command(self, *args, **kwargs):
        result = subprocess.run(args, capture_output=True, **kwargs)
        self.assertEqual(result.returncode, 0, (args, result.stdout, result.stderr))
        return result

    def test_packaged_image_and_overwrite_protection(self):
        from ds_store import DSStore

        with tempfile.TemporaryDirectory(prefix="PairDesk DMG test ") as directory:
            work = Path(directory)
            app = work / "PairDesk.app"
            contents = app / "Contents"
            (contents / "MacOS").mkdir(parents=True)
            (contents / "Resources").mkdir()
            shutil.copy("/usr/bin/true", contents / "MacOS/PairDesk")
            shutil.copy2(ROOT / "macos/Resources/PairDesk.icns", contents / "Resources/PairDesk.icns")
            with (contents / "Info.plist").open("wb") as stream:
                plistlib.dump({
                    "CFBundleIdentifier": "app.internal.pairdesk.dmg-test",
                    "CFBundleExecutable": "PairDesk",
                    "CFBundleName": "PairDesk",
                    "CFBundlePackageType": "APPL",
                    "CFBundleIconFile": "PairDesk",
                    "CFBundleShortVersionString": "0.0.0",
                    "CFBundleVersion": "1",
                }, stream)
            self.run_command("codesign", "--force", "--sign", "-", str(app))
            output = work / "installer with spaces.dmg"
            env = dict(os.environ, PAIRDESK_DISTRIBUTION_APP=str(app),
                       PAIRDESK_DMG_OUTPUT=str(output), PAIRDESK_DMG_PYTHON=sys.executable)
            command = ["bash", str(ROOT / "scripts/create-dmg.sh")]
            self.run_command(*command, env=env)
            digest = hashlib.sha256(output.read_bytes()).hexdigest()
            self.assertEqual(Path(str(output) + ".sha256").read_text(), f"{digest}  {output}\n")

            mount = work / "mounted"
            self.run_command("hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(output))
            try:
                visible = {p.name for p in mount.iterdir() if not p.name.startswith(".")}
                self.assertEqual(visible, {"PairDesk.app", "Applications"})
                self.assertEqual(os.readlink(mount / "Applications"), "/Applications")
                self.assertEqual((mount / ".background.tiff").read_bytes(),
                                 (ROOT / "scripts/dmg/background.tiff").read_bytes())
                self.run_command("codesign", "--verify", "--deep", "--strict", str(mount / "PairDesk.app"))
                with DSStore.open(str(mount / ".DS_Store"), "r") as store:
                    self.assertEqual(store["PairDesk.app"]["Iloc"], (170, 220))
                    self.assertEqual(store["Applications"]["Iloc"], (490, 220))
                    window = store["."]["bwsp"]
                    self.assertEqual(window["WindowBounds"], "{{160, 160}, {660, 520}}")
                    for key in ("ShowToolbar", "ShowSidebar", "ShowStatusBar", "ShowPathbar", "ShowTabView"):
                        self.assertFalse(window[key], key)
                    view = store["."]["icvp"]
                    self.assertEqual(view["backgroundType"], 2)
                    self.assertTrue(view["backgroundImageAlias"])
                    self.assertEqual(view["iconSize"], 112)
                    self.assertEqual(view["arrangeBy"], "none")
            finally:
                self.run_command("hdiutil", "detach", str(mount))

            retry = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(retry.returncode, 0)
            self.assertIn("Refusing to overwrite", retry.stderr)
            self.assertEqual(hashlib.sha256(output.read_bytes()).hexdigest(), digest)
            output.unlink()
            checksum_only = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertNotEqual(checksum_only.returncode, 0)
            self.assertIn("Refusing to overwrite", checksum_only.stderr)
            self.assertFalse(output.exists())
            self.assertFalse(list(work.glob("*.tmp.*.dmg")))


if __name__ == "__main__":
    unittest.main()
