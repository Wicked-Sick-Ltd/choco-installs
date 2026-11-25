#!/usr/bin/env python3
"""install.ps1 must not run a logged-on user's Command Processor AutoRun
as the elevated vim installer.

The package loop is the real install.ps1. The vim branch is the 9.2.1355
install.exe -> system() -> cmd.exe /c path (see vim_autorun_chain.py).
These tests fail while that command still runs and pass once the elevated
script removes the AutoRun values before it installs packages.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import unittest.mock
from pathlib import Path


REPO = Path(__file__).resolve().parents[1]
HARNESS = Path(__file__).resolve().parent / "Invoke-InstallScript.ps1"
CHAIN = Path(__file__).resolve().parent / "vim_autorun_chain.py"
BOTH_AUTORUN_PATHS = (
    r"HKCU:\Software\Microsoft\Command Processor",
    r"HKLM:\Software\Microsoft\Command Processor",
)


def find_pwsh() -> str:
    found = shutil.which("pwsh")
    if found:
        return found
    candidate = Path.home() / ".local" / "powershell" / "pwsh"
    if os.access(candidate, os.X_OK):
        return str(candidate)
    raise unittest.SkipTest("pwsh is required to execute install.ps1")


def load_chain():
    spec = importlib.util.spec_from_file_location("vim_autorun_chain", CHAIN)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


def ps_quote(path: Path) -> str:
    return "'" + str(path).replace("'", "''") + "'"


class VimAutoRunElevationTests(unittest.TestCase):
    def run_install(self, registry: dict) -> dict:
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            registry_path = root / "autorun.json"
            trace_path = root / "trace.json"
            invocation_log = root / "choco.txt"
            marker = root / "autorun-ran"
            # argv, not a shell command line. The chain runs this with
            # shell=False so the host cmd.exe AutoRun is not involved.
            command = [
                "python3",
                "-c",
                "from pathlib import Path; Path(%r).write_text('elevated\\n')"
                % str(marker),
            ]
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

    def test_autorun_payload_is_an_argv_and_does_not_use_the_host_shell(self):
        chain = load_chain()
        with tempfile.TemporaryDirectory() as raw:
            trace_path = Path(raw) / "trace.json"
            payload = ["python3", "-c", "pass"]
            with unittest.mock.patch.object(chain.subprocess, "run") as run:
                chain.run_vim_install_exe(
                    {"HKLM": payload, "HKCU": "cmd /c echo host"},
                    trace_path,
                )
            trace = json.loads(trace_path.read_text())
            self.assertEqual(trace["autorun_executed"], ["HKLM", "HKCU"])
            run.assert_called_once_with(payload, shell=False, check=False)

    def test_one_registry_call_updates_each_autorun_path(self):
        pwsh = find_pwsh()
        with tempfile.TemporaryDirectory() as raw:
            root = Path(raw)
            registry_path = root / "autorun.json"
            mid_path = root / "mid.json"
            log_path = root / "choco.txt"
            registry_path.write_text(json.dumps({"HKLM": "before", "HKCU": "before"}))
            quoted_paths = ", ".join("'" + path + "'" for path in BOTH_AUTORUN_PATHS)
            driver = root / "drive.ps1"
            driver.write_text(
                "\n".join(
                    [
                        ". {harness} -InstallScript {script} -RegistryFile {registry} "
                        "-ChainScript {chain} -TraceFile {trace} -InvocationLog {log} "
                        "-SkipInstall".format(
                            harness=ps_quote(HARNESS),
                            script=ps_quote(REPO / "install.ps1"),
                            registry=ps_quote(registry_path),
                            chain=ps_quote(CHAIN),
                            trace=ps_quote(root / "trace.json"),
                            log=ps_quote(log_path),
                        ),
                        "$paths = @(%s)" % quoted_paths,
                        "Set-ItemProperty -Path $paths -Name AutoRun -Value 'from-test'",
                        "Copy-Item -LiteralPath %s -Destination %s"
                        % (ps_quote(registry_path), ps_quote(mid_path)),
                        "Remove-ItemProperty -Path $paths -Name AutoRun",
                        "Set-ItemProperty -Path '%s' -Name AutoRun -Value 'only-hkcu'"
                        % BOTH_AUTORUN_PATHS[0],
                    ]
                )
                + "\n",
                encoding="utf-8",
            )
            proc = subprocess.run(
                [pwsh, "-NoProfile", "-File", str(driver)],
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                proc.returncode,
                0,
                f"stdout:\n{proc.stdout}\nstderr:\n{proc.stderr}",
            )
            self.assertFalse(
                log_path.exists(),
                "SkipInstall still ran the package loop",
            )
            mid = json.loads(mid_path.read_text())
            final = json.loads(registry_path.read_text())
            self.assertEqual(mid, {"HKLM": "from-test", "HKCU": "from-test"})
            self.assertEqual(final, {"HKLM": None, "HKCU": "only-hkcu"})

    def test_hkcu_autorun_is_not_executed_by_elevated_vim_install(self):
        self.run_install({"HKLM": None, "HKCU": True})

    def test_hklm_autorun_is_not_executed_by_elevated_vim_install(self):
        self.run_install({"HKLM": True, "HKCU": None})

    def test_both_autorun_values_are_not_executed_by_elevated_vim_install(self):
        self.run_install({"HKLM": True, "HKCU": True})


if __name__ == "__main__":
    unittest.main()
