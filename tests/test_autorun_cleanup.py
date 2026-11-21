#!/usr/bin/env python3
"""install.ps1 removes Command Processor AutoRun only for the install run.

The values have to be absent while packages install, and present again when
the script ends: after a normal run, when removal fails before anything is
installed, and when the pipeline is stopped during the package loop.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

RECOVERY_NAME = "choco-installs-autorun-recovery.json"


REPO = Path(__file__).resolve().parents[1]
HARNESS = Path(__file__).resolve().parent / "Invoke-AutoRunCleanup.ps1"

HKLM = r"HKLM:\Software\Microsoft\Command Processor"
HKLM_WOW = r"HKLM:\Software\WOW6432Node\Microsoft\Command Processor"
HKCU = r"HKCU:\Software\Microsoft\Command Processor"

ORIGINAL = {
    HKLM: {"kind": "String", "value": "echo stay-hklm"},
    HKLM_WOW: None,
    HKCU: {"kind": "ExpandString", "value": r"echo %SystemRoot%\stay"},
}


def find_pwsh() -> str:
    found = shutil.which("pwsh")
    if found:
        return found
    candidate = Path.home() / ".local" / "powershell" / "pwsh"
    if os.access(candidate, os.X_OK):
        return str(candidate)
    raise unittest.SkipTest("pwsh is required to execute install.ps1")


class AutoRunCleanupTests(unittest.TestCase):
    def recovery_path(self) -> Path:
        return Path(tempfile.gettempdir()) / RECOVERY_NAME

    def run_install(
        self,
        extra_env: dict | None = None,
        registry: dict | None = None,
        recovery: dict | None = None,
    ) -> tuple[subprocess.CompletedProcess[str], dict, list[str]]:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            registry_path = root / "autorun.json"
            invocation_log = root / "choco.txt"
            registry_path.write_text(json.dumps(ORIGINAL if registry is None else registry))
            recovery_path = self.recovery_path()
            if recovery_path.exists():
                recovery_path.unlink()
            if recovery is not None:
                recovery_path.write_text(json.dumps(recovery))
            env = os.environ.copy()
            env.pop("CHOCO_TEST_ABORT_REMOVE", None)
            env.pop("CHOCO_TEST_STOP_AT", None)
            env.pop("CHOCO_TEST_BOOTSTRAP_FAIL", None)
            env.pop("CHOCO_TEST_NO_CHOCO", None)
            env.pop("CHOCO_TEST_FAIL_RESTORE_PATH", None)
            env.pop("CHOCO_TEST_DACL_MODE", None)
            env.pop("CHOCO_TEST_DACL_SDDL", None)
            env.pop("CHOCO_TEST_DACL_OPEN_DENIED", None)
            env.pop("CHOCO_TEST_SAVED_COMSPEC", None)
            if extra_env:
                env.update(extra_env)
            proc = subprocess.run(
                [
                    find_pwsh(),
                    "-NoProfile",
                    "-File",
                    str(HARNESS),
                    "-InstallScript",
                    str(REPO / "install.ps1"),
                    "-RegistryFile",
                    str(registry_path),
                    "-InvocationLog",
                    str(invocation_log),
                ],
                capture_output=True,
                text=True,
                cwd=root,
                env=env,
            )
            restored = json.loads(registry_path.read_text())
            log = invocation_log.read_text().splitlines() if invocation_log.exists() else []
            return proc, restored, log

    def assert_restored(self, restored: dict) -> None:
        self.assertEqual(restored, ORIGINAL)

    def assert_absent_during_installs(self, log: list[str]) -> None:
        self.assertGreater(len(log), 0, "package loop did not run")
        for line in log:
            self.assertTrue(
                line.endswith("present=0"),
                f"AutoRun was still set while a package installed: {line}",
            )

    def test_restores_values_and_kinds_after_the_package_loop(self):
        proc, restored, log = self.run_install()
        self.assertEqual(
            proc.returncode,
            0,
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        self.assert_absent_during_installs(log)
        self.assertIn("install vim present=0", log)
        self.assertIn("install cascadia-code-nerd-font present=0", log)
        self.assert_restored(restored)

    def test_restores_when_removal_fails_before_any_install(self):
        proc, restored, log = self.run_install({"CHOCO_TEST_ABORT_REMOVE": "1"})
        self.assertNotEqual(
            proc.returncode,
            0,
            "a failed AutoRun removal must stop before packages install",
        )
        self.assertEqual(log, [], "packages ran after AutoRun removal failed")
        self.assertIn("Refusing to install packages", proc.stdout + proc.stderr)
        self.assert_restored(restored)

    def test_restores_when_the_pipeline_stops_during_the_loop(self):
        proc, restored, log = self.run_install({"CHOCO_TEST_STOP_AT": "vim"})
        self.assertNotEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assert_absent_during_installs(log)
        packages = [line.split()[1] for line in log]
        self.assertIn("googlechrome", packages)
        self.assertIn("vim", packages)
        self.assertNotIn("cascadia-code-nerd-font", packages)
        self.assert_restored(restored)

    def test_bootstrap_error_continues_the_loop_and_still_restores(self):
        proc, restored, log = self.run_install({"CHOCO_TEST_BOOTSTRAP_FAIL": "1"})
        self.assertEqual(
            proc.returncode,
            0,
            f"a statement-terminating bootstrap error skipped the rest of the run\n"
            f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        self.assert_absent_during_installs(log)
        self.assertIn("install vim present=0", log)
        self.assertIn("install cascadia-code-nerd-font present=0", log)
        self.assert_restored(restored)

    def test_missing_choco_is_a_per_package_failure(self):
        proc, restored, log = self.run_install({"CHOCO_TEST_NO_CHOCO": "1"})
        self.assertEqual(
            proc.returncode,
            0,
            f"a missing choco command aborted the script\nstdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
        )
        output = proc.stdout + proc.stderr
        self.assertIn("==> Installing googlechrome", output)
        self.assertIn("==> Installing cascadia-code-nerd-font", output)
        self.assertIn("Some package installs failed", output)
        self.assertNotIn("All packages installed successfully", output)
        self.assertEqual(log, [])
        self.assert_restored(restored)
        self.assertFalse(self.recovery_path().exists(), "recovery file was left after a finished run")

    def test_next_run_restores_values_saved_by_a_killed_process(self):
        empty = {HKLM: None, HKLM_WOW: None, HKCU: None}
        recovery = {
            "autorun": [
                {"path": HKLM, "kind": "String", "value": "echo stay-hklm"},
                {"path": HKCU, "kind": "ExpandString", "value": r"echo %SystemRoot%\stay"},
            ],
            "userComSpec": None,
        }
        proc, restored, log = self.run_install(registry=empty, recovery=recovery)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assert_absent_during_installs(log)
        self.assert_restored(restored)
        self.assertFalse(self.recovery_path().exists())

    def test_recovery_file_cannot_set_an_arbitrary_registry_path(self):
        empty = {HKLM: None, HKLM_WOW: None, HKCU: None}
        unexpected = r"HKLM:\Software\Unexpected"
        recovery = {
            "autorun": [
                {"path": unexpected, "kind": "String", "value": "echo planted"},
                {"path": HKCU, "kind": "ExpandString", "value": r"echo %SystemRoot%\stay"},
            ],
            "userComSpec": None,
        }
        proc, restored, log = self.run_install(registry=empty, recovery=recovery)
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertNotIn(unexpected, restored)
        self.assertEqual(restored[HKCU], {"kind": "ExpandString", "value": r"echo %SystemRoot%\stay"})
        self.assertIsNone(restored[HKLM])
        self.assert_absent_during_installs(log)
        self.assertFalse(self.recovery_path().exists())

    def test_failed_import_does_not_overwrite_the_recovery_file(self):
        empty = {HKLM: None, HKLM_WOW: None, HKCU: None}
        recovery = {
            "autorun": [
                {"path": HKLM, "kind": "String", "value": "echo stay-hklm"},
                {"path": HKCU, "kind": "ExpandString", "value": r"echo %SystemRoot%\stay"},
            ],
            "userComSpec": None,
        }
        proc, restored, _log = self.run_install(
            {"CHOCO_TEST_FAIL_RESTORE_PATH": HKCU},
            registry=empty,
            recovery=recovery,
        )
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        kept = json.loads(self.recovery_path().read_text())
        kept_paths = {entry["path"]: entry["value"] for entry in kept["autorun"]}
        self.assertEqual(kept_paths[HKCU], r"echo %SystemRoot%\stay")
        self.assertEqual(kept_paths[HKLM], "echo stay-hklm")
        self.assertIsNone(restored[HKCU])

    def test_deliberate_admin_only_dacl_is_restored_verbatim(self):
        # Same shape the script used to treat as its own temporary DACL:
        # protected, and every ACE is SYSTEM or Administrators.
        locked = "D:PAI(A;CI;KA;;;SY)(A;CI;KA;;;BA)"
        proc, restored, _log = self.run_install(
            {
                "CHOCO_TEST_DACL_MODE": "present",
                "CHOCO_TEST_DACL_SDDL": locked,
            }
        )
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn(f"COMMAND_PROCESSOR_DACL={locked}", proc.stdout)
        self.assertNotIn("COMMAND_PROCESSOR_DACL=inherit", proc.stdout)
        self.assert_restored(restored)

    def test_script_marker_without_a_saved_dacl_turns_inheritance_on(self):
        temporary = "D:P(A;;KA;;;SY)(A;;KA;;;BA)"
        proc, restored, _log = self.run_install(
            {
                "CHOCO_TEST_DACL_MODE": "marker",
                "CHOCO_TEST_DACL_SDDL": temporary,
            }
        )
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("COMMAND_PROCESSOR_DACL=inherit", proc.stdout)
        self.assertNotIn(temporary, proc.stdout)
        self.assert_restored(restored)

    def test_imported_dacl_is_kept_when_the_live_key_has_the_script_marker(self):
        locked = "D:PAI(A;CI;KA;;;SY)(A;CI;KA;;;BA)"
        temporary = "D:P(A;;KA;;;SY)(A;;KA;;;BA)"
        empty = {HKLM: None, HKLM_WOW: None, HKCU: None}
        recovery = {
            "autorun": [
                {"path": HKLM, "kind": "String", "value": "echo stay-hklm"},
                {"path": HKCU, "kind": "ExpandString", "value": r"echo %SystemRoot%\stay"},
            ],
            "userComSpec": None,
            "commandProcessorDacl": locked,
        }
        proc, restored, log = self.run_install(
            {
                "CHOCO_TEST_DACL_MODE": "marker",
                "CHOCO_TEST_DACL_SDDL": temporary,
            },
            registry=empty,
            recovery=recovery,
        )
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn(f"COMMAND_PROCESSOR_DACL={locked}", proc.stdout)
        self.assertNotIn("COMMAND_PROCESSOR_DACL=inherit", proc.stdout)
        self.assertNotIn(temporary, proc.stdout)
        self.assert_absent_during_installs(log)
        self.assert_restored(restored)
        self.assertFalse(self.recovery_path().exists())

    def test_imported_inherit_is_not_replaced_by_the_live_temporary_dacl(self):
        temporary = "D:P(A;;KA;;;SY)(A;;KA;;;BA)"
        empty = {HKLM: None, HKLM_WOW: None, HKCU: None}
        recovery = {
            "autorun": [
                {"path": HKLM, "kind": "String", "value": "echo stay-hklm"},
                {"path": HKCU, "kind": "ExpandString", "value": r"echo %SystemRoot%\stay"},
            ],
            "userComSpec": None,
            "commandProcessorDacl": "inherit",
        }
        proc, restored, log = self.run_install(
            {
                "CHOCO_TEST_DACL_MODE": "marker",
                "CHOCO_TEST_DACL_SDDL": temporary,
            },
            registry=empty,
            recovery=recovery,
        )
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("COMMAND_PROCESSOR_DACL=inherit", proc.stdout)
        self.assertNotIn(temporary, proc.stdout)
        self.assert_absent_during_installs(log)
        self.assert_restored(restored)

    def test_denied_marker_open_still_restores_comspec_and_autorun(self):
        locked = "D:PAI(A;CI;KA;;;SY)(A;CI;KA;;;BA)"
        proc, restored, _log = self.run_install(
            {
                "CHOCO_TEST_DACL_MODE": "present",
                "CHOCO_TEST_DACL_SDDL": locked,
                "CHOCO_TEST_DACL_OPEN_DENIED": "setvalue",
                "CHOCO_TEST_SAVED_COMSPEC": "kept-comspec",
            }
        )
        output = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("Unable to remove the temporary Command Processor marker", output)
        self.assertIn(f"COMMAND_PROCESSOR_DACL={locked}", proc.stdout)
        self.assertIn("RESUMED_USER_COMSPEC=kept-comspec", proc.stdout)
        self.assertNotIn("Unable to restore cmd.exe AutoRun or remove the integrity labels", output)
        self.assert_restored(restored)

    def test_denied_permission_open_still_resumes_comspec(self):
        proc, restored, _log = self.run_install(
            {
                "CHOCO_TEST_DACL_MODE": "present",
                "CHOCO_TEST_DACL_SDDL": "D:P(A;;KA;;;SY)(A;;KA;;;BA)",
                "CHOCO_TEST_DACL_OPEN_DENIED": "permissions",
                "CHOCO_TEST_SAVED_COMSPEC": "kept-comspec",
            }
        )
        output = proc.stdout + proc.stderr
        self.assertEqual(proc.returncode, 0, f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}")
        self.assertIn("Unable to restore permissions on HKCU\\Software\\Microsoft\\Command Processor", output)
        self.assertIn("RESUMED_USER_COMSPEC=kept-comspec", proc.stdout)
        self.assertNotIn("Unable to restore cmd.exe AutoRun or remove the integrity labels", output)
        self.assert_restored(restored)


if __name__ == "__main__":
    unittest.main()
