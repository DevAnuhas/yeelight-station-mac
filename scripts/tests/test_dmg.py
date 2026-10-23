"""Isolated command fixtures: never sign, upload, mount, install, or launch an app.

Run: python3 -m unittest discover -s scripts/tests -p 'test_dmg.py' -v
"""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest

PROJECT = Path(__file__).resolve().parents[2]
SUBMISSION_ID = "12345678-1234-1234-1234-123456789abc"

# One dispatcher behind fake command names. PATH is confined to the fixture's
# bin directory followed by system tools; all signing/network/mount tools here
# are intercepted before invoking either release script.
MOCK = r'''
import hashlib, json, os, pathlib, plistlib, shutil, sys
p = pathlib.Path
tool, args = p(sys.argv[0]).name, sys.argv[1:]
root = p(os.environ["FIXTURE"])
with (root / "calls.jsonl").open("a") as f:
    f.write(json.dumps([tool, *args]) + "\n")
def copy(source, target):
    if p(source).is_dir(): shutil.copytree(source, target, dirs_exist_ok=True, symlinks=True)
    else: shutil.copy2(source, target)
def emit(value): print(json.dumps(value))
sid = "12345678-1234-1234-1234-123456789abc"
if tool == "uname": print("Darwin")
elif tool == "ditto": copy(*args)
elif tool == "plutil":
    raw = p(args[-1]).read_bytes()
    data = json.loads(raw) if raw.lstrip().startswith(b"{") else plistlib.loads(raw)
    print(data[args[args.index("-extract") + 1]])
elif tool == "codesign":
    if os.environ.get("BAD_SIGNATURE"): sys.exit(1)
    mount_path = root / "mount-path"
    if (os.environ.get("BAD_MOUNTED_SIGNATURE") and "--verify" in args
            and mount_path.exists() and p(args[-1]).is_relative_to(mount_path.read_text())):
        print("fixture: mounted app signature rejected", file=sys.stderr)
        sys.exit(1)
    if "-d" in args:
        raw = p(args[-1]).read_bytes() if p(args[-1]).is_file() else b"app"
        digest = hashlib.sha1(raw.split(b"\nTICKET")[0]).hexdigest()
        print("CDHash=" + digest)
        print("Timestamp=Oct 24, 2026")
elif tool == "lipo":
    if args[-1] == os.environ.get("BAD_ARCH"): sys.exit(1)
elif tool == "spctl":
    if os.environ.get("BAD_GATEKEEPER"): sys.exit(1)
elif tool == "xcrun":
    if args[0] == "--find": print("/fake/" + args[1])
    elif args[:2] == ["notarytool", "submit"]:
        if not os.environ.get("NO_SUBMISSION_ID"): emit({"id": sid})
        sys.exit(int(os.environ.get("SUBMIT_EXIT", "0")))
    elif args[:2] == ["notarytool", "wait"]: sys.exit(1)
    elif args[:2] == ["notarytool", "info"]:
        emit({"id": "wrong" if os.environ.get("BAD_STATUS_ID") else sid,
              "status": os.environ.get("NOTARY_STATUS", "Accepted")})
    elif args[:2] == ["notarytool", "log"]:
        p(args[-1]).write_text(json.dumps({"jobId": sid,
            "status": os.environ.get("NOTARY_STATUS", "Accepted")}))
    elif args[:2] == ["stapler", "staple"]:
        with p(args[-1]).open("ab") as f: f.write(b"\nTICKET")
    elif args[:2] == ["stapler", "validate"]:
        if os.environ.get("BAD_STAPLE"): sys.exit(1)
    else: raise AssertionError(args)
elif tool == "dmgbuild":
    if os.environ.get("BAD_DMGBUILD"): sys.exit(1)
    p(args[-1]).write_bytes(b"SIGNED DMG FIXTURE")
    (root / "image-path").write_text(args[-1])
elif tool == "hdiutil":
    if args[0] == "verify": pass
    elif args[0] == "attach":
        mount = p(args[args.index("-mountpoint") + 1])
        copy(root / "dist/Yeelight Station.app", mount / "Yeelight Station.app")
        copy(root / "LICENSE", mount / "License.txt")
        (mount / "Applications").symlink_to("/Applications")
        (root / "mount-path").write_text(str(mount))
        (root / "mounted").touch()
        sys.stdout.buffer.write(plistlib.dumps({}))
    elif args[0] == "info":
        if os.environ.get("BAD_MOUNT_PLIST"): print("invalid"); sys.exit(0)
        images = [{"image-path": "/unrelated/image.dmg", "system-entities": [{"dev-entry": "/dev/disk99"}]}]
        if (root / "mounted").exists():
            images.append({"image-path": (root / "image-path").read_text(),
                "system-entities": [{"dev-entry": "/dev/disk77"}]})
        sys.stdout.buffer.write(plistlib.dumps({"images": images}))
    elif args[0] == "detach":
        assert args[1] == "/dev/disk77", "Must never detach an unrelated image"
        if os.environ.get("BAD_DETACH"): sys.exit(1)
        (root / "mounted").unlink(missing_ok=True)
    else: raise AssertionError(args)
else: raise AssertionError(tool)
'''


class DMGScripts(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="station-dmg-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "scripts").mkdir()
        for name in ("build-dmg.sh", "notarize-dmg.sh"):
            shutil.copy2(PROJECT / "scripts" / name, self.root / "scripts" / name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for tool in ("uname", "ditto", "plutil", "codesign", "xcrun", "lipo", "hdiutil", "spctl"):
            self.mock(self.bin / tool)
        self.app = self.root / "dist/Yeelight Station.app"
        (self.app / "Contents/MacOS").mkdir(parents=True)
        (self.app / "Contents/Resources").mkdir()
        (self.app / "Contents/MacOS/YeelightStation").write_bytes(b"fixture")
        (self.app / "Contents/Resources/Station.icns").write_bytes(b"fixture")
        (self.app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "dev.yeelightstation.mac",
            "CFBundleExecutable": "YeelightStation",
            "CFBundleShortVersionString": "0.2.2",
        }))
        (self.root / "LICENSE").write_text("MIT fixture notice")
        self.dmg = self.root / "dist/Yeelight-Station-0.2.2-universal.dmg"
        self.dmg.write_bytes(b"SIGNED DMG FIXTURE")
        self.original = self.dmg.read_bytes()
        self.receipt = self.root / "receipts" / hashlib.sha256(self.original).hexdigest()
        venv = self.root / ".tools/dmgbuild/bin"
        venv.mkdir(parents=True)
        self.mock(venv / "dmgbuild")
        # Only intercept the installed-version assertion; the cleanup parser runs
        # the real Python so malformed plist/device handling is actually tested.
        (venv / "python3").write_text(
            "#!/bin/bash\nif [ \"${1:-}\" = -c ]; then exit 0; fi\nexec "
            + shutil.which("python3") + ' "$@"\n')
        (venv / "python3").chmod(0o755)
        self.env = {**os.environ, "PATH": f"{self.bin}:/usr/bin:/bin:/usr/sbin:/sbin",
                    "FIXTURE": str(self.root), "CODE_SIGN_IDENTITY": "FIXTURE-ID",
                    "KEYCHAIN_PROFILE": "Fixture-Profile", "NOTARY_TIMEOUT": "1s",
                    "NOTARY_RECEIPTS_DIR": str(self.root / "receipts")}
        for name in ("DIST_DIR", "DEVELOPMENT_TEAM"):
            self.env.pop(name, None)

    def mock(self, path):
        path.write_text(f"#!{sys.executable}\n" + MOCK)
        path.chmod(0o755)

    def run_script(self, script="notarize-dmg.sh", *args, success=True, **env):
        result = subprocess.run(["/bin/bash", str(self.root / "scripts" / script), *args],
                                env={**self.env, **env}, capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def calls(self, tool=None, subcommand=None):
        path = self.root / "calls.jsonl"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [c for c in calls if (tool is None or c[0] == tool)
                and (subcommand is None or c[1:1 + len(subcommand)] == subcommand)]

    def test_success_staples_private_copy_and_assesses_open(self):
        self.run_script()
        self.assertEqual(self.dmg.read_bytes(), self.original + b"\nTICKET")
        self.assertEqual((self.receipt / "submission.dmg").read_bytes(), self.original)
        self.assertTrue((self.receipt / "completed.txt").exists())
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "submit"])), 1)
        self.assertIn("--no-wait", self.calls("xcrun", ["notarytool", "submit"])[0])
        assessment = self.calls("spctl")[0]
        self.assertIn("open", assessment)
        self.assertIn("context:primary-signature", assessment)

    def test_timeout_can_resume_without_second_upload(self):
        self.run_script(success=False, NOTARY_STATUS="In Progress")
        self.assertEqual(self.dmg.read_bytes(), self.original)
        self.assertEqual((self.receipt / "submission-id.txt").read_text().strip(), SUBMISSION_ID)
        self.run_script("notarize-dmg.sh", "--resume", str(self.receipt))
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "submit"])), 1)
        self.assertEqual(len(list(self.receipt.glob("check-*"))), 2)

    def test_duplicate_invocation_refuses_resubmission(self):
        self.run_script(success=False, NOTARY_STATUS="In Progress")
        self.run_script(success=False)
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "submit"])), 1)

    def test_ambiguous_upload_preserves_id_for_resume(self):
        self.run_script(success=False, SUBMIT_EXIT="1")
        self.assertTrue((self.receipt / "submission-id.txt").exists())
        self.run_script("notarize-dmg.sh", "--resume", str(self.receipt))
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "submit"])), 1)

    def test_missing_submission_id_never_retries(self):
        self.run_script(success=False, NO_SUBMISSION_ID="1")
        self.run_script(success=False)
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "submit"])), 1)
        self.assertTrue((self.receipt / "submission.json").exists())

    def test_rejected_or_wrong_job_never_staples(self):
        for failure in ({"NOTARY_STATUS": "Invalid"}, {"BAD_STATUS_ID": "1"}):
            with self.subTest(failure=failure):
                if self.receipt.exists(): shutil.rmtree(self.receipt)
                self.run_script(success=False, **failure)
                self.assertEqual(self.dmg.read_bytes(), self.original)
        self.assertEqual(self.calls("xcrun", ["stapler", "staple"]), [])

    def test_failed_gatekeeper_preserves_output_and_stage(self):
        self.run_script(success=False, BAD_GATEKEEPER="1")
        self.assertEqual(self.dmg.read_bytes(), self.original)
        self.assertEqual(len(list(self.dmg.parent.glob(".Station-notarized-dmg.*"))), 1)
        self.assertTrue(list(self.receipt.glob("check-*/gatekeeper.txt")))

    def test_changed_dmg_or_submission_refuses_resume(self):
        self.run_script(success=False, NOTARY_STATUS="In Progress")
        self.dmg.write_bytes(b"DIFFERENT IMAGE")
        self.run_script("notarize-dmg.sh", "--resume", str(self.receipt), success=False)
        self.dmg.write_bytes(self.original)
        (self.receipt / "submission.dmg").write_bytes(b"DIFFERENT IMAGE")
        self.run_script("notarize-dmg.sh", "--resume", str(self.receipt), success=False)
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "wait"])), 1)

    def test_completed_stapled_hash_resumes(self):
        self.run_script()
        self.run_script("notarize-dmg.sh", "--resume", str(self.receipt))
        self.assertEqual(len(self.calls("xcrun", ["notarytool", "submit"])), 1)

    def test_empty_profile_or_bad_signature_never_uploads(self):
        for failure in ({"KEYCHAIN_PROFILE": ""}, {"BAD_SIGNATURE": "1"}):
            self.run_script(success=False, **failure)
        self.assertEqual(self.calls("xcrun", ["notarytool", "submit"]), [])

    def test_symlink_output_is_rejected(self):
        self.dmg.unlink()
        self.dmg.symlink_to(self.root / "LICENSE")
        self.run_script(success=False)
        self.run_script("build-dmg.sh", success=False)
        self.assertEqual((self.root / "LICENSE").read_text(), "MIT fixture notice")

    def test_build_uses_plist_version_and_detaches_only_owned_image(self):
        self.run_script("build-dmg.sh")
        self.assertTrue(self.dmg.exists())
        self.assertEqual(self.calls("hdiutil", ["detach"]), [["hdiutil", "detach", "/dev/disk77"]])
        signing = [c for c in self.calls("codesign") if "--sign" in c]
        self.assertEqual(len(signing), 1)
        self.assertIn("--timestamp", signing[0])
        self.assertIn("dev.yeelightstation.dmg", signing[0])
        self.assertFalse(list(self.dmg.parent.glob(".Station-dmg.*")))

    def test_build_validation_errors_are_not_masked(self):
        for failure in ({"BAD_ARCH": "arm64"}, {"BAD_SIGNATURE": "1"}, {"BAD_STAPLE": "1"}):
            with self.subTest(failure=failure):
                self.run_script("build-dmg.sh", success=False, **failure)
                self.assertEqual(self.dmg.read_bytes(), self.original)
        self.assertEqual(self.calls("dmgbuild"), [])

    def test_mounted_signature_failure_blocks_signing_and_publication(self):
        original_stat = self.dmg.stat()
        result = self.run_script("build-dmg.sh", success=False, BAD_MOUNTED_SIGNATURE="1")
        self.assertEqual(self.dmg.read_bytes(), self.original)
        self.assertEqual(self.dmg.stat().st_ino, original_stat.st_ino)
        self.assertEqual(self.dmg.stat().st_mtime_ns, original_stat.st_mtime_ns)
        self.assertEqual([c for c in self.calls("codesign") if "--sign" in c], [])
        stages = list(self.dmg.parent.glob(".Station-dmg.*"))
        self.assertEqual(len(stages), 1)
        stage = stages[0].resolve()
        mounted_app = stage / "verify/Yeelight Station.app"
        verifications = self.calls("codesign", ["--verify"])
        self.assertEqual([Path(c[-1]) for c in verifications],
                         [stage / "Yeelight Station.app", mounted_app])
        self.assertTrue(all("--strict" in c for c in verifications))
        # The clean staged copy passed all checks before the mounted copy failed.
        self.assertEqual(len(self.calls("dmgbuild")), 1)
        self.assertEqual(self.calls("spctl")[-1][-1], str(stage / "Yeelight Station.app"))
        self.assertIn("fixture: mounted app signature rejected",
                      (stage / "packaged-app-validation.log").read_text())
        self.assertIn("Packaged app validation failed", result.stderr)
        self.assertIn(str(stage), result.stderr)
        self.assertTrue((stage / "distribution.dmg").is_file())
        self.assertEqual(self.calls("hdiutil", ["detach"]),
                         [["hdiutil", "detach", "/dev/disk77"]])
        self.assertFalse((self.root / "mounted").exists())

    def test_settings_do_not_apply_finder_flags_to_signed_app(self):
        settings = runpy.run_path(str(PROJECT / "packaging/dmg/settings.py"), init_globals={
            "defines": {"app": str(self.app), "resources": str(self.root / "artwork"),
                        "license": str(self.root / "LICENSE")},
            "hide": [], "hide_extensions": [],
        })
        signed_app_names = [destination for source, destination in settings["files"]
                            if Path(source) == self.app]
        self.assertTrue(signed_app_names, "The signed app must actually be packaged")
        # dmgbuild implements both options by writing FinderInfo on their targets.
        # Test the executed policy, allowing flags for unrelated unsigned files.
        for flag in ("hide", "hide_extensions"):
            for target in settings[flag]:
                for name in signed_app_names:
                    with self.subTest(flag=flag, target=target):
                        flagged = str(Path(target)).casefold()
                        signed = str(Path(name)).casefold()
                        self.assertFalse(flagged == signed or flagged.startswith(signed + "/"),
                                         f"{flag} would modify signed app metadata: {target}")

    def test_bad_mount_inventory_or_detach_preserves_stage_and_output(self):
        for failure in ({"BAD_MOUNT_PLIST": "1"}, {"BAD_DETACH": "1"}):
            with self.subTest(failure=failure):
                self.run_script("build-dmg.sh", success=False, **failure)
                self.assertEqual(self.dmg.read_bytes(), self.original)
                self.assertTrue(list(self.dmg.parent.glob(".Station-dmg.*")))
        self.assertEqual(self.calls("codesign", ["--force"]), [])


if __name__ == "__main__":
    unittest.main()
