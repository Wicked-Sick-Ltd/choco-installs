#!/usr/bin/env python3
"""Stand-in for the vim 9.2.1355 install.exe path that install.ps1 reaches.

Built from the sources read for the unpinned `choco install vim` package
(community package vim 9.2.1355, archive gvim_9.2.1355_x64.zip
sha256 9ff76c3b8a7b29ff9a6e0160636bdf415426d574a588fcf117f32ad5e947b28d):

- chocolatey-community package tools/chocolateyinstall.ps1 runs
  install.exe with the arguments from helpers.ps1 Get-Statement, via
  Start-ChocolateyProcessAsAdmin. Chocolatey CLI 2.7.5 starts that
  executable with UseShellExecute false and, when the caller is already
  elevated, does not set Verb RunAs, so the child keeps the caller token.
- vim tag v9.2.1355 src/dosinst.c main(), when argc > 1, sets interactive
  to 0, calls command_line_setup_choices, then install(). install() calls
  install_OLE_register() whenever has_gvim is set. check_unpack() sets
  has_gvim when gvim.exe is beside install.exe. The published zip contains
  vim/vim92/gvim.exe, vim/vim92/install.exe and vim/vim92/filetype.vim, and
  src/version.h defines VIM_VERSION_NODOT as "vim92", so check_unpack passes.
  install_OLE_register() sprintf's "\"%s\\gvim.exe\" -silent -register"
  and passes it to system(). That format string is present in the shipped
  install.exe.
- Windows SDK CRT source 10.0.22621.3 ucrt/exec/system.cpp common_system()
  spawns COMSPEC (else cmd.exe) with argv {comspec, "/c", command}. The
  shipped install.exe contains the adjacent literals COMSPEC, cmd.exe, /c.
  ucrt/exec/cenvarg.cpp construct_command_line() joins those argv entries
  with spaces and does not insert /D. ucrt/exec/spawnv.cpp execute_command()
  passes that line to CreateProcess with no alternate token.
- Microsoft's cmd documentation: if /d is not specified, cmd executes
  HKLM and HKCU Software\\Microsoft\\Command Processor\\AutoRun before the
  /c command. Default ComSpec is %SystemRoot%\\system32\\cmd.exe.
"""

from __future__ import annotations

import argparse
import json
import subprocess
from pathlib import Path


# vim v9.2.1355 src/version.h VIM_VERSION_NODOT
VIM_VERSION_NODOT = "vim92"

# Default COMSPEC from the ComSpec registry value documented by Microsoft.
DEFAULT_COMSPEC = r"C:\Windows\System32\cmd.exe"

# helpers.ps1 Get-Statement() with no package parameters.
GET_STATEMENT = (
    "-create-batfiles vim gvim evim view gview vimdiff gvimdiff vimtutor "
    "-install-openwith -add-start-menu "
    "-create-vimrc -vimrc-remap no -vimrc-behave default -vimrc-compat all "
    "-install-popup -install-icons"
)

# Zip layout verified for gvim_9.2.1355_x64.zip. On a fresh unzip the only
# version directory is vim92, so helpers.ps1 Create-SymbolicLink's `cmd /c`
# loop does not run. install.exe's system() call still does.
ZIP_HAS_GVIM = True
ZIP_HAS_FILETYPE = True
ZIP_VERSION_DIR = "vim92"


def install_register_command(installdir: str) -> str:
    """dosinst.c install_OLE_register sprintf format."""
    return f'"{installdir}\\gvim.exe" -silent -register'


def system_argv(command: str, comspec: str = DEFAULT_COMSPEC) -> list[str]:
    """ucrt system.cpp common_system argument vector. No /D switch."""
    return [comspec, "/c", command]


def command_line_has_disable_autorun(argv: list[str]) -> bool:
    """True only when a discrete argv element is /D. cenvarg does not add one."""
    return any(arg.lower() == "/d" for arg in argv[1:])


def run_vim_install_exe(registry: dict, trace_path: Path) -> None:
    """Non-interactive install.exe, then the system() -> cmd AutoRun step."""
    installdir = rf"C:\tools\vim\{VIM_VERSION_NODOT}"
    trace = {
        "package_statement": GET_STATEMENT,
        "version_dir": ZIP_VERSION_DIR,
        "reached_system": False,
        "argv": [],
        "autorun_executed": [],
    }

    # dosinst.c check_unpack: directory tail must be VIM_VERSION_NODOT,
    # filetype.vim must exist, and gvim.exe sets has_gvim.
    directory_ok = installdir.rstrip("\\").lower().endswith("\\" + VIM_VERSION_NODOT)
    if not directory_ok or not ZIP_HAS_FILETYPE or not ZIP_HAS_GVIM:
        trace["stop"] = "check_unpack"
        trace_path.write_text(json.dumps(trace))
        return

    # main(): argc > 1 because Start-ChocolateyProcessAsAdmin passes
    # Get-Statement. interactive = 0, then install() is called.
    # install() registers OLE whenever has_gvim is set. -register-OLE is
    # ignored; the call is unconditional.
    has_gvim = ZIP_HAS_GVIM
    if has_gvim:
        command = install_register_command(installdir)
        argv = system_argv(command)
        trace["reached_system"] = True
        trace["argv"] = argv
        if not command_line_has_disable_autorun(argv):
            # cmd reads HKLM and then HKCU when /d is absent.
            for hive in ("HKLM", "HKCU"):
                value = registry.get(hive)
                if value:
                    trace["autorun_executed"].append(hive)
                    subprocess.run(value, shell=True, check=False)

    trace_path.write_text(json.dumps(trace))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--registry", required=True)
    parser.add_argument("--trace", required=True)
    args = parser.parse_args()
    registry_path = Path(args.registry)
    registry = json.loads(registry_path.read_text())
    run_vim_install_exe(registry, Path(args.trace))


if __name__ == "__main__":
    main()
