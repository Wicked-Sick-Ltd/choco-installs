#!/usr/bin/env python3
"""Spec for the nodejs-lts install path chosen by install.ps1.

install.ps1 installs the Chocolatey package nodejs-lts. That package runs the
official Node.js MSI. These tests drive the package loop in install.ps1 and a
stand-in of that MSI built from the tables and sources cited below. They fail
while a logged-on user's Node.js InstallPath is still able to choose the
directory that is appended to the machine PATH.

The stand-in is not a memory of Windows Installer. Each step is the
corresponding operation from the cited source.

Harness registry surface (what a fix in install.ps1 can do from this Linux
run). Calls are elevated, matching an Administrator PowerShell session. The
logged-on user's standard token then runs again immediately before AppSearch:

  Test-Path / Get-ItemProperty / Remove-ItemProperty / Set-ItemProperty
  New-Item / Remove-Item / Get-Acl / Set-Acl
  reg.exe delete|add

Get-Acl returns an object with SetOwner(account) and
SetAccessRuleProtection(isProtected, preserveInheritance). Set-Acl writes that
object back. SetAccessRuleProtection only records that inheritance is off; it
leaves explicit ACEs in place, so removing the logged-on user's FullControl
entry takes a separate ACL change. HKCU:\\SOFTWARE\\Node.js starts owned by the
logged-on user, with an explicit full-control entry for that user. Clearing
the value leaves that entry in place, so the user can write the value again
before the MSI reads it.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
INSTALL_SCRIPT = REPO_ROOT / "install.ps1"

# nodejs-lts 26.13.1 embeds this MSI (community.chocolatey.org package page,
# tools\node-v26.13.1-x64.msi, approved 13 Nov 2026). install.ps1 does not pin
# a version; `choco install -y nodejs-lts` installs that current package.
# Tables exported from the published MSI with msiinfo.
NODE_MSI_VERSION = "26.13.1"
APPSEARCH_ROWS = (
    # AppSearch.idt order. A later hit overwrites the property.
    {"property": "INSTALLDIR", "signature": "InstallPathRegistry"},
    {"property": "INSTALLDIR", "signature": "InstallPathRegistryCU"},
)
REGLOCATOR_ROWS = {
    # RegLocator.idt. Root 2 = HKLM, root 1 = HKCU. Type 18 = raw | 64-bit.
    "InstallPathRegistry": {"root": "HKLM", "key": r"SOFTWARE\Node.js", "name": "InstallPath", "type": 18},
    "InstallPathRegistryCU": {"root": "HKCU", "key": r"SOFTWARE\Node.js", "name": "InstallPath", "type": 18},
}
# LockPermissions.idt Permission column for INSTALLDIR\CreateFolder.
LOCK_USERS = -1609564128  # 0xA0100020 GENERIC_READ|GENERIC_EXECUTE|SYNCHRONIZE|FILE_EXECUTE
LOCK_ADMIN = 268435456  # 0x10000000 GENERIC_ALL
# Directory.idt: INSTALLDIR -> ProgramFiles64Folder -> TARGETDIR, default "nodejs".
PROGRAM_FILES = r"C:\Program Files"
DEFAULT_INSTALL_DIR = PROGRAM_FILES + r"\nodejs"
ATTACKER = "attacker"
USERS = "Users"
AUTHENTICATED_USERS = "Authenticated Users"
ADMINISTRATORS = "BUILTIN\\Administrators"
LOCAL_SYSTEM = "NT AUTHORITY\\SYSTEM"
FILE_DELETE_CHILD = 0x40
FILE_WRITE_DATA = 0x2
FILE_ADD_FILE = 0x2
DELETE = 0x00010000
GENERIC_ALL = 0x10000000
GENERIC_WRITE = 0x40000000
# Package tools\chocolateyinstall.ps1 for nodejs-lts 26.13.1. No INSTALLDIR.
PACKAGE_SILENT_ARGS = (
    "/qn /norestart /l*v "
    f'"C:\\Windows\\Temp\\nodejs-lts.{NODE_MSI_VERSION}.MsiInstall.log"'
)

# Rights the logged-on user's standard token receives. UAC removes
# administrative SIDs from that token, so the Administrators ACE does not
# grant this principal access.
ATTACKER_SIDS = {ATTACKER, USERS, AUTHENTICATED_USERS}


def _pwsh() -> str:
    for candidate in (
        shutil.which("pwsh"),
        os.path.expanduser("~/pwsh/pwsh"),
        "/home/ubuntu/pwsh/pwsh",
        "/usr/bin/pwsh",
    ):
        if candidate and os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    raise AssertionError("PowerShell 7 (pwsh) is required to execute install.ps1")


def _normalize_reg_path(path: str) -> str:
    text = path.replace("/", "\\")
    for prefix in ("HKCU:\\", "HKCU:", "HKEY_CURRENT_USER\\", "HKLM:\\", "HKLM:", "HKEY_LOCAL_MACHINE\\"):
        if text.upper().startswith(prefix.upper()):
            hive = "HKCU" if prefix.upper().startswith("HKCU") or "CURRENT_USER" in prefix.upper() else "HKLM"
            rest = text[len(prefix):].lstrip("\\")
            parts = [part for part in rest.split("\\") if part]
            return hive + "\\" + "\\".join(parts)
    if text.upper().startswith("HKCU\\") or text.upper().startswith("HKLM\\"):
        hive, _, rest = text.partition("\\")
        parts = [part for part in rest.split("\\") if part]
        return hive.upper() + "\\" + "\\".join(parts)
    return text


def _key(state: dict, path: str) -> dict | None:
    return state["registry"].get(_normalize_reg_path(path))


def _ensure_key(state: dict, path: str, owner: str) -> dict:
    norm = _normalize_reg_path(path)
    key = state["registry"].get(norm)
    if key is None:
        # Elevated creation still leaves the logged-on user on the default DACL
        # until the script replaces that DACL.
        key = {"owner": owner, "aces": [{"sid": ATTACKER, "rights": ["full"]}], "values": {}}
        state["registry"][norm] = key
    return key


def attacker_can_write_key(state: dict, path: str) -> bool:
    """Owner WRITE_DAC, or an allow ACE the standard token actually holds.

    Owner implicit WRITE_DAC: "Owner of a New Object" (Microsoft Learn). An
    Owner Rights ACE (S-1-3-4) would suppress it; the Node MSI DACL has none.
    RegDeleteKeyW opens the subkey itself with DELETE; the parent handle's
    rights do not delete it (winreg.h).
    """
    key = _key(state, path)
    if key is None:
        norm = _normalize_reg_path(path)
        if "\\" not in norm:
            return False
        return attacker_can_write_key(state, norm.rsplit("\\", 1)[0])
    if key.get("owner") == ATTACKER:
        return True
    for ace in key.get("aces", []):
        if ace.get("sid") in ATTACKER_SIDS and ("full" in ace.get("rights", []) or "write" in ace.get("rights", [])):
            return True
    return False


def attacker_plant_install_path(state: dict) -> None:
    """What the logged-on user can still do when msiexec starts AppSearch."""
    target = r"HKCU\SOFTWARE\Node.js"
    wanted = state["payload"]["install_path"]
    if _key(state, target) is None:
        if not attacker_can_write_key(state, r"HKCU\SOFTWARE"):
            return
        state["registry"][target] = {
            "owner": ATTACKER,
            "aces": [{"sid": ATTACKER, "rights": ["full"]}],
            "values": {},
        }
    if attacker_can_write_key(state, target):
        state["registry"][target].setdefault("values", {})["InstallPath"] = wanted


def _reg_value(state: dict, hive: str, key: str, name: str) -> str | None:
    found = _key(state, hive + "\\" + key)
    if not found:
        return None
    value = found.get("values", {}).get(name)
    if value is None or value == "":
        return None
    return str(value)


def parse_public_properties(msi_args: str) -> dict[str, str]:
    """Public properties on the msiexec command line. Quotes are optional."""
    props: dict[str, str] = {}
    index = 0
    text = msi_args
    while index < len(text):
        while index < len(text) and text[index].isspace():
            index += 1
        start = index
        while index < len(text) and not text[index].isspace() and text[index] != "=":
            index += 1
        token = text[start:index]
        if index < len(text) and text[index] == "=" and token.isupper() and token.isidentifier():
            index += 1
            if index < len(text) and text[index] == '"':
                index += 1
                end = text.find('"', index)
                if end < 0:
                    end = len(text)
                props[token] = text[index:end]
                index = end + 1
            else:
                end = index
                while end < len(text) and not text[end].isspace():
                    end += 1
                props[token] = text[index:end]
                index = end
        else:
            if index < len(text) and text[index] == "=":
                index += 1
            while index < len(text) and not text[index].isspace():
                index += 1
    return props


def _normalize_dir(path: str) -> str:
    # wine dlls/msi/action.c msi_normalize_path (wine 10.0 b0738596) adds a
    # trailing backslash when the path does not already end with one.
    trimmed = path.rstrip(" \t")
    if not trimmed.endswith("\\"):
        trimmed += "\\"
    return trimmed


def resolve_install_dir(properties: dict[str, str]) -> str:
    """wine msi_resolve_target_folder: a set directory property wins, else parent + default."""
    if properties.get("INSTALLDIR"):
        return _normalize_dir(properties["INSTALLDIR"])
    program_files = _normalize_dir(properties.get("ProgramFiles64Folder", PROGRAM_FILES))
    return program_files + "nodejs\\"


def appsearch(state: dict, properties: dict[str, str]) -> None:
    """ACTION_AppSearch from wine 10.0 dlls/msi/appsearch.c.

    ITERATE_AppSearch (lines 1086-1121) calls msi_set_property whenever the
    signature has a value. It does not keep a value that was already set.
    Microsoft’s AppSearch table says the same: a found signature overrides the
    property’s initialized value, including a command-line value.
    search_reg (lines 376-388, 455-456) reads HKEY_CURRENT_USER or
    HKEY_LOCAL_MACHINE and, for msidbLocatorTypeRawValue, uses the raw string.
    """
    for row in APPSEARCH_ROWS:
        locator = REGLOCATOR_ROWS[row["signature"]]
        if locator["type"] & 0x0F != 2:
            continue
        value = _reg_value(state, locator["root"], locator["key"], locator["name"])
        if value:
            properties[row["property"]] = value


def _mask_grants(mask: int, right: int) -> bool:
    if mask & GENERIC_ALL:
        return True
    if right in (FILE_WRITE_DATA, FILE_ADD_FILE, DELETE, FILE_DELETE_CHILD) and mask & GENERIC_WRITE:
        return True
    return bool(mask & right)


def _attacker_mask(entry: dict) -> int:
    mask = 0
    for ace in entry.get("aces", []):
        if ace.get("sid") in ATTACKER_SIDS:
            mask |= int(ace.get("mask", 0))
    if entry.get("owner") == ATTACKER:
        # Implicit WRITE_DAC. No Owner Rights ACE is present on these objects.
        mask |= 0x00040000
    return mask


def attacker_can_replace_file(state: dict, file_path: str) -> bool:
    """True when the standard token can make the next node.exe its own program.

    FILE_DELETE_CHILD (0x40) on a directory allows deleting the files and
    directories it contains, including read-only files (WinNT.h file access
    rights). The owner can also rewrite the DACL and then replace the file.
    """
    norm = _normalize_dir(file_path).rstrip("\\")
    leaf = state["files"].get(norm)
    if leaf and _mask_grants(_attacker_mask(leaf), FILE_WRITE_DATA):
        return True
    if leaf and leaf.get("owner") == ATTACKER:
        return True
    directory = norm.rsplit("\\", 1)[0]
    while directory and directory not in ("C:", ""):
        entry = state["dirs"].get(_normalize_dir(directory).rstrip("\\"))
        if entry and (
            entry.get("owner") == ATTACKER
            or _mask_grants(_attacker_mask(entry), FILE_DELETE_CHILD)
            or _mask_grants(_attacker_mask(entry), FILE_ADD_FILE)
        ):
            return True
        parent = directory.rsplit("\\", 1)[0]
        if parent == directory:
            break
        directory = parent
    return False


def _apply_lock_permissions(state: dict, directory: str) -> None:
    """LockPermissions rows for INSTALLDIR. The table has no owner column.

    Users and Authenticated Users receive 0xA0100020 (read/execute).
    Administrators and LocalSystem receive GENERIC_ALL. The standard token
    does not hold the Administrators SID (UAC, "How User Account Control
    works": administrative SIDs are removed from the standard token).
    """
    norm = _normalize_dir(directory).rstrip("\\")
    entry = state["dirs"].setdefault(norm, {"owner": ADMINISTRATORS, "aces": []})
    entry["aces"] = [
        {"sid": USERS, "mask": LOCK_USERS & 0xFFFFFFFF},
        {"sid": AUTHENTICATED_USERS, "mask": LOCK_USERS & 0xFFFFFFFF},
        {"sid": ADMINISTRATORS, "mask": LOCK_ADMIN},
        {"sid": LOCAL_SYSTEM, "mask": LOCK_ADMIN},
    ]


def apply_msi(state: dict, extra_args: str) -> None:
    """nodejs-lts 26.13.1 chocolateyInstall.ps1 plus Chocolatey 2.7.5.

    Install-ChocolateyInstallPackage.ps1 lines 262 and 335-345 build
    `msiexec /i <msi> <silentArgs> <chocolateyInstallArguments>`.
    PowershellService.cs lines 501-503 copy --install-arguments into
    chocolateyInstallArguments (StringResources.cs line 294). The package
    silent args do not contain INSTALLDIR. Start-ChocolateyProcessAsAdmin.ps1
    lines 131-134 start that process as the current token when the session is
    already elevated, which is how install.ps1 is run.
    """
    state["msi_applied"] = True
    attacker_plant_install_path(state)
    properties = {
        "ProgramFiles64Folder": PROGRAM_FILES,
    }
    command = f'/i "node-v{NODE_MSI_VERSION}-x64.msi" {PACKAGE_SILENT_ARGS} {extra_args}'.strip()
    properties.update(parse_public_properties(command))
    appsearch(state, properties)
    install_dir = resolve_install_dir(properties)
    state["last_install_dir"] = install_dir
    state["last_msiexec"] = command
    _apply_lock_permissions(state, install_dir)
    official = _normalize_dir(install_dir).rstrip("\\") + "\\node.exe"
    existing = state["files"].get(official)
    if existing is None:
        parent = state["dirs"][_normalize_dir(install_dir).rstrip("\\")]
        state["files"][official] = {
            "owner": parent.get("owner", ADMINISTRATORS),
            "aces": [dict(ace) for ace in parent.get("aces", [])],
            "content": "OFFICIAL",
        }
    else:
        # File is not in LockPermissions, so an existing file keeps its
        # security descriptor. InstallFiles still replaces the bytes.
        existing["content"] = "OFFICIAL"
    machine_path = state["machine_path"]
    addition = install_dir.rstrip("\\")
    # Environment.idt: `=-*PATH` / `[~];[INSTALLDIR]`.
    # wine env_parse_flags sets ENV_MOD_MACHINE|ENV_MOD_APPEND; open_env_key
    # writes HKLM\System\CurrentControlSet\Control\Session Manager\Environment.
    lowered = [item.rstrip("\\").lower() for item in machine_path]
    if addition.lower() not in lowered:
        machine_path.append(addition)
    resolved = resolve_node(state)
    state["resolved_node"] = resolved
    if resolved and attacker_can_replace_file(state, resolved):
        state["files"][resolved]["content"] = "ATTACKER"
        state["attack_succeeded"] = True
        state["attack_detail"] = (
            "machine PATH resolves node.exe to "
            f"{resolved}, and the logged-on user can replace that file"
        )
    else:
        state["attack_succeeded"] = False
        state["attack_detail"] = (
            "node.exe on the machine PATH is not replaceable by the logged-on user"
            if resolved
            else "node.exe is not on the machine PATH"
        )


def resolve_node(state: dict) -> str | None:
    for directory in state["machine_path"]:
        candidate = directory.rstrip("\\") + "\\node.exe"
        if candidate in state["files"]:
            return candidate
    return None


def fresh_state(install_path: str, hklm_install_path: str | None = None) -> dict:
    parent = install_path.rstrip("\\").rsplit("\\", 1)[0]
    state = {
        "payload": {"install_path": install_path.rstrip("\\")},
        "registry": {
            r"HKCU\SOFTWARE": {
                "owner": ATTACKER,
                "aces": [{"sid": ATTACKER, "rights": ["full"]}],
                "values": {},
            },
            r"HKCU\SOFTWARE\Node.js": {
                "owner": ATTACKER,
                "aces": [{"sid": ATTACKER, "rights": ["full"]}],
                "values": {"InstallPath": install_path.rstrip("\\")},
            },
        },
        "dirs": {
            PROGRAM_FILES: {
                "owner": ADMINISTRATORS,
                "aces": [
                    {"sid": USERS, "mask": LOCK_USERS & 0xFFFFFFFF},
                    {"sid": ADMINISTRATORS, "mask": GENERIC_ALL},
                ],
            },
            parent: {
                "owner": ATTACKER,
                "aces": [{"sid": ATTACKER, "mask": GENERIC_ALL | FILE_DELETE_CHILD | FILE_ADD_FILE | DELETE}],
            },
            install_path.rstrip("\\"): {
                "owner": ATTACKER,
                "aces": [{"sid": ATTACKER, "mask": GENERIC_ALL | FILE_DELETE_CHILD | FILE_ADD_FILE | DELETE}],
            },
        },
        "files": {
            install_path.rstrip("\\") + "\\node.exe": {
                "owner": ATTACKER,
                "aces": [{"sid": ATTACKER, "mask": GENERIC_ALL}],
                "content": "ATTACKER",
            }
        },
        "machine_path": [r"C:\Windows\System32", r"C:\Windows"],
        "attack_succeeded": False,
        "attack_detail": "",
        "last_install_dir": "",
        "last_msiexec": "",
        "resolved_node": None,
        "msi_applied": False,
    }
    if hklm_install_path:
        state["registry"][r"HKLM\SOFTWARE\Node.js"] = {
            "owner": LOCAL_SYSTEM,
            "aces": [{"sid": ADMINISTRATORS, "rights": ["full"]}],
            "values": {"InstallPath": hklm_install_path.rstrip("\\")},
        }
    return state


def _run_reg(state_path: Path, args: list[str]) -> str:
    state = json.loads(state_path.read_text())
    op = args[0]
    path = ""
    name = ""
    value = ""
    owner = ""
    protected = False
    aces: list[dict] = []
    index = 1
    while index < len(args):
        flag = args[index]
        if flag == "--path":
            path = args[index + 1]
            index += 2
        elif flag == "--name":
            name = args[index + 1]
            index += 2
        elif flag == "--value":
            value = args[index + 1]
            index += 2
        elif flag == "--owner":
            owner = args[index + 1]
            index += 2
        elif flag == "--protected":
            protected = args[index + 1] == "true"
            index += 2
        elif flag == "--aces":
            aces = json.loads(args[index + 1])
            if isinstance(aces, dict):
                aces = [aces]
            index += 2
        else:
            raise SystemExit(f"unknown reg flag {flag}")
    norm = _normalize_reg_path(path) if path else ""

    if op == "test":
        print("yes" if _key(state, norm) else "no")
        return ""
    if op == "get-value":
        key = _key(state, norm)
        print("" if not key else str(key.get("values", {}).get(name, "")))
        return ""
    if op == "remove-value":
        key = _key(state, norm)
        if key:
            key.get("values", {}).pop(name, None)
        state_path.write_text(json.dumps(state))
        return ""
    if op == "remove-key":
        state["registry"].pop(norm, None)
        state_path.write_text(json.dumps(state))
        return ""
    if op == "create-key":
        if _key(state, norm) is None:
            # Created by the elevated token. The user SID is still on the
            # default DACL until the script replaces it.
            state["registry"][norm] = {
                "owner": ADMINISTRATORS,
                "aces": [{"sid": ATTACKER, "rights": ["full"]}],
                "values": {},
            }
        state_path.write_text(json.dumps(state))
        return ""
    if op == "set-value":
        key = _ensure_key(state, norm, ADMINISTRATORS)
        key.setdefault("values", {})[name] = value
        state_path.write_text(json.dumps(state))
        return ""
    if op == "get-acl":
        key = _key(state, norm)
        if key is None:
            print(json.dumps({"owner": "", "aces": []}))
        else:
            print(json.dumps({"owner": key.get("owner", ""), "aces": key.get("aces", [])}))
        return ""
    if op == "set-acl":
        key = _key(state, norm)
        if key is None:
            key = _ensure_key(state, norm, owner or ADMINISTRATORS)
        if owner:
            key["owner"] = owner
        key["aces"] = aces
        key["protected"] = protected
        state_path.write_text(json.dumps(state))
        return ""
    raise SystemExit(f"unknown reg op {op}")


HARNESS = r"""
$ErrorActionPreference = 'Stop'
$statePath = $env:NODE_INSTALL_TEST_STATE
$python = $env:NODE_INSTALL_TEST_PYTHON
$scriptPath = $env:NODE_INSTALL_TEST_SCRIPT

function Invoke-Reg {
    param([Parameter(ValueFromRemainingArguments = $true)][string[]]$RegArgs)
    $output = & $python $env:NODE_INSTALL_TEST_RUNNER --reg @RegArgs
    if ($LASTEXITCODE -ne 0) { throw "registry helper failed: $RegArgs" }
    return ("$output").Trim()
}

function ConvertTo-RegPath {
    param([string]$Path)
    $text = "$Path"
    if ($text -match '^(HKCU|HKLM):\\') { return $text }
    if ($text -match '^(HKCU|HKLM)\\') {
        return ($text -replace '\\', ':\\', 1)
    }
    return $text
}

function Test-RegistryPath {
    param([string]$Path)
    return "$Path" -like 'HKCU:*' -or "$Path" -like 'HKLM:*' -or "$Path" -like 'HKCU\*' -or "$Path" -like 'HKLM\*'
}

class NodeRegAcl {
    [string]$Owner
    [bool]$DaclProtected
    [System.Collections.Generic.List[object]]$Aces
    NodeRegAcl() { $this.Aces = [System.Collections.Generic.List[object]]::new() }
    [void]SetOwner([object]$Account) { $this.Owner = "$Account" }
    [void]SetAccessRuleProtection([bool]$IsProtected, [bool]$PreserveInheritance) {
        # Inheritance off removes inherited ACEs only. This model stores
        # explicit entries, so they stay until a later ACL edit removes them.
        $this.DaclProtected = $IsProtected
    }
}

function Test-Path {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [string]$LiteralPath,
        [string]$PathType,
        [switch]$Force
    )
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (Test-RegistryPath $target) {
        $answer = Invoke-Reg test --path $target
        return $answer -eq 'yes'
    }
    if ($LiteralPath) {
        return Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath
    }
    return Microsoft.PowerShell.Management\Test-Path -Path $Path
}

function Get-ItemProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath, [string]$Name)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (-not (Test-RegistryPath $target)) { throw "Get-ItemProperty is only simulated for HKCU/HKLM" }
    $raw = Invoke-Reg get-value --path $target --name $Name
    return [pscustomobject]@{ $Name = $raw }
}

function Remove-ItemProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath, [string]$Name, [switch]$Force)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (-not (Test-RegistryPath $target)) { throw "Remove-ItemProperty is only simulated for HKCU/HKLM" }
    Invoke-Reg remove-value --path $target --name $Name | Out-Null
}

function Set-ItemProperty {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath, [string]$Name, [string]$Value)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (-not (Test-RegistryPath $target)) { throw "Set-ItemProperty is only simulated for HKCU/HKLM" }
    Invoke-Reg set-value --path $target --name $Name --value $Value | Out-Null
}

function New-Item {
    [CmdletBinding()]
    param(
        [string]$Path,
        [string]$Name,
        [string]$ItemType,
        [switch]$Force
    )
    if ($Path -and (Test-RegistryPath $Path)) {
        $full = if ($Name) { Join-Path $Path $Name } else { $Path }
        Invoke-Reg create-key --path $full | Out-Null
        return
    }
    if ($PSBoundParameters.ContainsKey('Force')) { $null = $PSBoundParameters.Remove('Force') }
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters | Out-Null
}

function Remove-Item {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath, [switch]$Recurse, [switch]$Force)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (Test-RegistryPath $target) {
        Invoke-Reg remove-key --path $target | Out-Null
        return
    }
    $bound = @{}
    if ($LiteralPath) { $bound.LiteralPath = $LiteralPath } else { $bound.Path = $Path }
    if ($Recurse) { $bound.Recurse = $true }
    if ($Force) { $bound.Force = $true }
    Microsoft.PowerShell.Management\Remove-Item @bound
}

function Get-Acl {
    [CmdletBinding()]
    param([string]$Path, [string]$LiteralPath)
    $target = if ($LiteralPath) { $LiteralPath } else { $Path }
    if (-not (Test-RegistryPath $target)) { throw "Get-Acl is only simulated for HKCU/HKLM" }
    $json = Invoke-Reg get-acl --path $target
    $parsed = $json | ConvertFrom-Json
    $acl = [NodeRegAcl]::new()
    $acl.Owner = [string]$parsed.owner
    foreach ($ace in @($parsed.aces)) {
        $acl.Aces.Add(@{ sid = [string]$ace.sid; rights = @($ace.rights) })
    }
    return $acl
}

function Set-Acl {
    [CmdletBinding(DefaultParameterSetName = 'ByPath')]
    param(
        [Parameter(ParameterSetName = 'ByPath', Position = 0, Mandatory = $true)]
        [string]$Path,

        [Parameter(ParameterSetName = 'ByLiteralPath', Mandatory = $true)]
        [string]$LiteralPath,

        [Parameter(Mandatory = $true, Position = 1)]
        [object]$AclObject
    )
    $target = if ($PSCmdlet.ParameterSetName -eq 'ByLiteralPath') { $LiteralPath } else { $Path }
    if (-not (Test-RegistryPath $target)) { throw "Set-Acl is only simulated for HKCU/HKLM" }
    $aces = @()
    foreach ($ace in @($AclObject.Aces)) {
        if ($null -eq $ace) { continue }
        $aces += @{ sid = [string]$ace.sid; rights = @($ace.rights) }
    }
    if ($aces.Count -eq 0) {
        $payload = '[]'
    }
    else {
        $payload = ConvertTo-Json -InputObject $aces -Compress -Depth 5
        if ($aces.Count -eq 1 -and -not $payload.Trim().StartsWith('[')) {
            $payload = '[' + $payload + ']'
        }
    }
    $protected = 'false'
    if ($AclObject.DaclProtected) { $protected = 'true' }
    Invoke-Reg set-acl --path $target --owner "$($AclObject.Owner)" --protected $protected --aces $payload | Out-Null
}

function reg {
    # No parameter block. An advanced function binds -v to -Verbose and drops it.
    $RegArgs = @($args)
    $command = $RegArgs[0]
    $target = $RegArgs[1]
    if ($command -eq 'delete') {
        $name = ''
        for ($i = 0; $i -lt $RegArgs.Count; $i++) {
            if ($RegArgs[$i] -eq '/v' -or $RegArgs[$i] -eq '-v') { $name = $RegArgs[$i + 1] }
        }
        if ($name) {
            Invoke-Reg remove-value --path $target --name $name | Out-Null
        }
        else {
            Invoke-Reg remove-key --path $target | Out-Null
        }
        return
    }
    if ($command -eq 'add') {
        $name = ''
        $data = ''
        for ($i = 0; $i -lt $RegArgs.Count; $i++) {
            if ($RegArgs[$i] -eq '/v') { $name = $RegArgs[$i + 1] }
            if ($RegArgs[$i] -eq '/d') { $data = $RegArgs[$i + 1] }
        }
        Invoke-Reg create-key --path $target | Out-Null
        if ($name) { Invoke-Reg set-value --path $target --name $name --value $data | Out-Null }
    }
}

function choco {
    # No parameter block, so flags such as -y are arguments rather than parameters.
    $ChocoArgs = @($args)
    $package = $null
    $extra = ''
    for ($i = 0; $i -lt $ChocoArgs.Count; $i++) {
        $arg = [string]$ChocoArgs[$i]
        if ($arg -like '--install-arguments=*' -or $arg -like '--ia=*') {
            $extra = $arg.Substring($arg.IndexOf('=') + 1)
        }
        elseif ($arg -eq '--install-arguments' -or $arg -eq '--ia' -or $arg -eq '--installargs') {
            $extra = [string]$ChocoArgs[$i + 1]
            $i++
        }
        elseif ($arg -notlike '-*' -and $arg -ne 'install' -and $arg -ne 'upgrade') {
            $package = $arg
        }
    }
    if ($package -eq 'nodejs-lts') {
        & $python $env:NODE_INSTALL_TEST_RUNNER --apply-msi $statePath --extra-args "$extra"
        if ($LASTEXITCODE -ne 0) { throw "msi stand-in failed" }
    }
    & $python -c 'import sys; sys.exit(0)'
}

if ($env:NODE_INSTALL_TEST_SKIP_INSTALL -ne '1') {
    $tokens = $null
    $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$tokens, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) { throw ($errors | Out-String) }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $ast.ParamBlock) {
        $parts.Add($ast.ParamBlock.Extent.Text) | Out-Null
    }
    foreach ($stmt in $ast.EndBlock.Statements) {
        $text = $stmt.Extent.Text
        if ($text -like '*community.chocolatey.org/install.ps1*') { continue }
        $parts.Add($text) | Out-Null
    }
    # param() is only legal at the start of a scriptblock, not under Invoke-Expression.
    $replay = [scriptblock]::Create(($parts -join "`n"))
    & $replay
}
"""


def run_install_script(state: dict) -> dict:
    with tempfile.TemporaryDirectory() as tmp:
        state_path = Path(tmp) / "state.json"
        state_path.write_text(json.dumps(state))
        harness = Path(tmp) / "harness.ps1"
        harness.write_text(HARNESS)
        env = os.environ.copy()
        env.update(
            {
                "NODE_INSTALL_TEST_STATE": str(state_path),
                "NODE_INSTALL_TEST_PYTHON": shutil.which("python3") or "python3",
                "NODE_INSTALL_TEST_SCRIPT": str(INSTALL_SCRIPT),
                "NODE_INSTALL_TEST_RUNNER": str(Path(__file__).resolve()),
            }
        )
        completed = subprocess.run(
            [_pwsh(), "-NoProfile", "-File", str(harness)],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                "install.ps1 harness failed\n"
                + completed.stdout[-4000:]
                + "\n"
                + completed.stderr[-4000:]
            )
        if "has not been set" in completed.stderr:
            raise AssertionError(
                "install.ps1 replay left a parameter uninitialized\n"
                + completed.stderr[-4000:]
            )
        return json.loads(state_path.read_text())


def main_cli(argv: list[str]) -> int:
    if argv[1] == "--reg":
        # state path is NODE_INSTALL_TEST_STATE
        _run_reg(Path(os.environ["NODE_INSTALL_TEST_STATE"]), argv[2:])
        return 0
    if argv[1] == "--apply-msi":
        state_path = Path(argv[2])
        extra = ""
        if "--extra-args" in argv:
            extra = argv[argv.index("--extra-args") + 1]
        state = json.loads(state_path.read_text())
        apply_msi(state, extra)
        state_path.write_text(json.dumps(state))
        return 0
    raise SystemExit(f"unknown command {argv[1]}")


class NodeMsiStandInTests(unittest.TestCase):
    """The stand-in itself: these lock the MSI behaviour the script is measured against."""

    def test_current_user_path_is_appended_to_the_machine_path(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node")
        apply_msi(state, "")
        self.assertTrue(state["attack_succeeded"], state["attack_detail"])
        self.assertTrue(
            state["resolved_node"].lower().startswith(r"c:\users\alice\stage\node"),
            state["resolved_node"],
        )

    def test_command_line_installdir_is_overridden_while_the_value_exists(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node")
        apply_msi(state, 'INSTALLDIR="C:\\Program Files\\nodejs"')
        self.assertTrue(state["attack_succeeded"], state["attack_detail"])
        self.assertIn("alice", state["last_install_dir"].lower())

    def test_machine_install_path_does_not_win_over_a_later_current_user_hit(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node", hklm_install_path=DEFAULT_INSTALL_DIR)
        apply_msi(state, "")
        self.assertTrue(state["attack_succeeded"], state["attack_detail"])

    def test_clearing_the_value_without_removing_write_access_is_replayed(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node")
        state["registry"][r"HKCU\SOFTWARE\Node.js"]["values"].pop("InstallPath", None)
        apply_msi(state, "")
        self.assertTrue(state["attack_succeeded"], state["attack_detail"])

    def test_program_files_is_used_when_the_user_cannot_rewrite_the_value(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node")
        key = state["registry"][r"HKCU\SOFTWARE\Node.js"]
        key["owner"] = LOCAL_SYSTEM
        key["aces"] = [{"sid": ADMINISTRATORS, "rights": ["full"]}]
        key["values"].pop("InstallPath", None)
        apply_msi(state, "")
        self.assertFalse(state["attack_succeeded"], state["attack_detail"])
        self.assertTrue(
            state["resolved_node"].lower().startswith(r"c:\program files\nodejs"),
            state["resolved_node"],
        )
        self.assertEqual(state["files"][state["resolved_node"]]["content"], "OFFICIAL")


def _ps_quote(path: Path) -> str:
    return "'" + str(path).replace("'", "''") + "'"


def run_harness_snippet(state: dict, body: str) -> dict:
    """Dot-source the stubs and run body without replaying install.ps1."""
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        state_path = root / "state.json"
        state_path.write_text(json.dumps(state))
        harness = root / "harness.ps1"
        harness.write_text(HARNESS)
        driver = root / "drive.ps1"
        driver.write_text(
            "$env:NODE_INSTALL_TEST_SKIP_INSTALL = '1'\n. "
            + _ps_quote(harness)
            + "\n"
            + body
            + "\n",
            encoding="utf-8",
        )
        env = os.environ.copy()
        env.update(
            {
                "NODE_INSTALL_TEST_STATE": str(state_path),
                "NODE_INSTALL_TEST_PYTHON": shutil.which("python3") or "python3",
                "NODE_INSTALL_TEST_SCRIPT": str(INSTALL_SCRIPT),
                "NODE_INSTALL_TEST_RUNNER": str(Path(__file__).resolve()),
            }
        )
        completed = subprocess.run(
            [_pwsh(), "-NoProfile", "-File", str(driver)],
            cwd=REPO_ROOT,
            env=env,
            text=True,
            capture_output=True,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                "harness snippet failed\n" + completed.stdout[-2000:] + "\n" + completed.stderr[-2000:]
            )
        return json.loads(state_path.read_text())


class HarnessContractTests(unittest.TestCase):
    def test_positional_set_acl_keeps_the_explicit_attacker_ace(self) -> None:
        result = run_harness_snippet(
            fresh_state(r"C:\Users\alice\stage\node"),
            "\n".join(
                [
                    "$acl = Get-Acl 'HKCU:\\SOFTWARE\\Node.js'",
                    "$acl.SetOwner('NT AUTHORITY\\SYSTEM')",
                    "$acl.SetAccessRuleProtection($true, $false)",
                    "if ($acl.Aces.Count -lt 1) { throw 'SetAccessRuleProtection removed an explicit ACE' }",
                    "Set-Acl 'HKCU:\\SOFTWARE\\Node.js' $acl",
                ]
            ),
        )
        key = result["registry"][r"HKCU\SOFTWARE\Node.js"]
        self.assertEqual(key["owner"], "NT AUTHORITY\\SYSTEM")
        self.assertTrue(key["protected"])
        self.assertTrue(
            any(ace.get("sid") == ATTACKER and "full" in ace.get("rights", []) for ace in key["aces"]),
            key["aces"],
        )

    def test_reg_dash_v_removes_the_value_and_leaves_the_key(self) -> None:
        result = run_harness_snippet(
            fresh_state(r"C:\Users\alice\stage\node"),
            "reg delete 'HKCU\\SOFTWARE\\Node.js' -v InstallPath /f",
        )
        key = result["registry"].get(r"HKCU\SOFTWARE\Node.js")
        self.assertIsNotNone(key, result["registry"])
        self.assertNotIn("InstallPath", key.get("values", {}))

    def test_choco_install_y_reaches_the_msi(self) -> None:
        result = run_harness_snippet(
            fresh_state(r"C:\Users\alice\stage\node"),
            "choco install -y nodejs-lts",
        )
        self.assertTrue(result["msi_applied"], result.get("attack_detail"))


class InstallScriptTests(unittest.TestCase):
    def assert_official_machine_node(self, result: dict) -> None:
        self.assertTrue(result.get("msi_applied"), "nodejs-lts MSI did not run")
        resolved = result.get("resolved_node")
        self.assertTrue(resolved, "machine PATH did not resolve node.exe")
        self.assertNotIn("alice", resolved.lower(), result.get("attack_detail"))
        self.assertEqual(result["files"][resolved]["content"], "OFFICIAL")
        self.assertFalse(result["attack_succeeded"], result.get("attack_detail"))

    def test_logged_on_user_install_path_does_not_become_machine_node(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node")
        result = run_install_script(state)
        self.assert_official_machine_node(result)

    def test_existing_machine_install_path_does_not_keep_the_current_user_path(self) -> None:
        state = fresh_state(r"C:\Users\alice\stage\node", hklm_install_path=DEFAULT_INSTALL_DIR)
        result = run_install_script(state)
        self.assert_official_machine_node(result)


if __name__ == "__main__":
    import sys

    if len(sys.argv) > 1 and sys.argv[1] in {"--reg", "--apply-msi"}:
        sys.exit(main_cli(sys.argv))
    unittest.main()
