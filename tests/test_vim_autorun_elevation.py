#!/usr/bin/env python3
"""install.ps1 must not run a logged-on user's Command Processor AutoRun
as the elevated vim installer.

The package loop is the real install.ps1. The vim branch is the 9.2.1355
install.exe -> system() -> cmd.exe /c path (see vim_autorun_chain.py).
These tests fail while that command still runs and pass once the elevated
script removes the AutoRun values before it installs packages.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HARNESS = Path(__file__).resolve().parent / "Invoke-InstallScript.ps1"
CHAIN = Path(__file__).resolve().parent / "vim_autorun_chain.py"


def find_pwsh() -> str:
    found = shutil.which("pwsh")
    if found:
        return found
    candidate = Path.home() / ".local" / "powershell" / "pwsh"
    if os.access(candidate, os.X_OK):
        return str(candidate)
    raise unittest.SkipTest("pwsh is required to execute install.ps1")


class VimAutoRunElevationTests(unittest.TestCase):
    def run_install(self, registry: dict) -> dict:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            registry_path = root / "autorun.json"
            trace_path = root / "trace.json"
            invocation_log = root / "choco.txt"
            marker = root / "autorun-ran"
            command = (
                "python3 -c "
                + json.dumps(
                    "from pathlib import Path; Path(%r).write_text('elevated\\n')"
                    % str(marker)
                )
            )
            # The attacker-controlled value is the command stored before the
            # script runs. Substitute it into whichever hives the case sets.
            concrete = {
                hive: (command if value else None) for hive, value in registry.items()
            }
            registry_path.write_text(json.dumps(concrete))

            script = Path(os.environ.get("INSTALL_PS1", REPO / "install.ps1"))
            proc = subprocess.run(
                [
                    find_pwsh(),
                    "-NoProfile",
                    "-File",
                    str(HARNESS),
                    "-InstallScript",
                    str(script),
                    "-RegistryFile",
                    str(registry_path),
                    "-ChainScript",
                    str(CHAIN),
                    "-TraceFile",
                    str(trace_path),
                    "-InvocationLog",
                    str(invocation_log),
                ],
                capture_output=True,
                text=True,
                cwd=root,
            )
            self.assertEqual(
                proc.returncode,
                0,
                "install.ps1 did not reach the end of the package loop\n"
                f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
            )
            invocations = invocation_log.read_text().splitlines()
            self.assertIn(
                "install vim",
                invocations,
                "the package loop never installed vim, so the AutoRun path "
                "was not exercised",
            )
            self.assertTrue(trace_path.exists(), "vim install chain did not run")
            trace = json.loads(trace_path.read_text())
            self.assertTrue(trace["reached_system"], trace)
            argv = trace["argv"]
            self.assertEqual(argv[1], "/c", argv)
            self.assertNotIn("/d", [arg.lower() for arg in argv])
            self.assertEqual(
                trace["autorun_executed"],
                [],
                "AutoRun ran inside the elevated vim install.exe system() "
                f"command: {trace['autorun_executed']}",
            )
            self.assertFalse(
                marker.exists(),
                "AutoRun wrote its side effect before the script finished",
            )
            return trace

    def test_hkcu_autorun_is_not_executed_by_elevated_vim_install(self):
        self.run_install({"HKLM": None, "HKCU": True})

    def test_hklm_autorun_is_not_executed_by_elevated_vim_install(self):
        self.run_install({"HKLM": True, "HKCU": None})

    def test_both_autorun_values_are_not_executed_by_elevated_vim_install(self):
        self.run_install({"HKLM": True, "HKCU": True})


if __name__ == "__main__":
    unittest.main()
