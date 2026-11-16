# =========================================================
# Chocolatey bootstrap for a new Windows machine
# =========================================================

[CmdletBinding()]
param(
    [string]$LogPath = "",
    [switch]$EnableLogging
)

$ErrorActionPreference = 'Continue'
Set-StrictMode -Version Latest

# Configure optional logging
$UseLogging = $EnableLogging.IsPresent -or -not [string]::IsNullOrWhiteSpace($LogPath)
if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
    try {
        $logDir = Split-Path -Path $LogPath -Parent
        if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
            New-Item -ItemType Directory -Path $logDir -Force | Out-Null
        }
    }
    catch {
        Write-Warning "Unable to create log directory for '$LogPath'. Logging disabled. Error: $($_.Exception.Message)"
        $UseLogging = $false
    }
}
elseif ($UseLogging) {
    $LogPath = Join-Path -Path $PSScriptRoot -ChildPath ("install-{0}.log" -f (Get-Date -Format "yyyyMMdd-HHmmss"))
}

if ($UseLogging) {
    Write-Host "Logging enabled: $LogPath" -ForegroundColor Cyan
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($UseLogging) {
        Add-Content -Path $LogPath -Value ("[{0}] {1}" -f (Get-Date -Format "s"), $Message)
    }
}

# cmd.exe runs the Command Processor AutoRun values before its command unless it
# is started with /D, and package installers (for example vim's install.exe via
# system()) start cmd.exe /c with this session's administrator token. Any
# non-elevated process of the logged-on user can write the HKCU value, so every
# key on the path cmd.exe opens gets a High integrity no-write-up label before
# the values are removed: Medium integrity processes then cannot re-create the
# value or rename/replace those keys until the label is removed after the loop.
$AutoRunKeyPaths = @(
    'HKLM:\Software\Microsoft\Command Processor',
    'HKLM:\Software\WOW6432Node\Microsoft\Command Processor',
    'HKCU:\Software\Microsoft\Command Processor'
)
$UserAutoRunKeyChain = @('Software', 'Software\Microsoft', 'Software\Microsoft\Command Processor')
$OnWindows = [System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT

if ($OnWindows) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;

public static class RegistryIntegrityLabel
{
    const uint LABEL_SECURITY_INFORMATION = 0x10;
    const uint SDDL_REVISION_1 = 1;

    // RegSetKeySecurity changes only this key; SetSecurityInfo would walk the whole subtree.
    [DllImport("advapi32.dll")]
    static extern int RegSetKeySecurity(SafeRegistryHandle key, uint info, IntPtr descriptor);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern bool ConvertStringSecurityDescriptorToSecurityDescriptorW(string sddl, uint revision, out IntPtr descriptor, IntPtr length);

    [DllImport("kernel32.dll")]
    static extern IntPtr LocalFree(IntPtr memory);

    public static void Set(RegistryKey key, string sddl)
    {
        IntPtr descriptor;
        if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1, out descriptor, IntPtr.Zero))
            throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            int status = RegSetKeySecurity(key.Handle, LABEL_SECURITY_INFORMATION, descriptor);
            if (status != 0) throw new Win32Exception(status);
        }
        finally { LocalFree(descriptor); }
    }
}
'@
}

function Set-UserKeyIntegrityLabel {
    param(
        [Parameter(Mandatory = $true)]
        [string]$SubKey,

        # 'S:(ML;;NW;;;HI)' locks the key; 'S:' (empty SACL) restores the default label.
        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    $rights = [System.Security.AccessControl.RegistryRights]'ReadPermissions, TakeOwnership'
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($SubKey, [Microsoft.Win32.RegistryKeyPermissionCheck]::Default, $rights)
    if ($null -eq $key) {
        throw "HKCU\$SubKey does not exist."
    }
    try {
        [RegistryIntegrityLabel]::Set($key, $Label)
    }
    finally {
        $key.Close()
    }
}

function Unlock-UserAutoRunKeyChain {
    foreach ($subKey in $UserAutoRunKeyChain) {
        try {
            Set-UserKeyIntegrityLabel -SubKey $subKey -Label 'S:'
        }
        catch {
            Write-Warning "Unable to remove the integrity label from HKCU\$subKey. Error: $($_.Exception.Message)"
            Write-Log "FAIL remove integrity label: HKCU\$subKey"
        }
    }
}

function Assert-NoCommandProcessorAutoRun {
    $remaining = New-Object System.Collections.Generic.List[string]
    $locations = @(
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry64 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::LocalMachine; View = [Microsoft.Win32.RegistryView]::Registry32 },
        @{ Hive = [Microsoft.Win32.RegistryHive]::CurrentUser; View = [Microsoft.Win32.RegistryView]::Default }
    )

    foreach ($location in $locations) {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($location.Hive, $location.View)
        try {
            $key = $base.OpenSubKey('Software\Microsoft\Command Processor')
            if ($null -ne $key) {
                try {
                    if ($null -ne $key.GetValue('AutoRun', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)) {
                        $remaining.Add(("{0} ({1})" -f $key.Name, $location.View)) | Out-Null
                    }
                }
                finally {
                    $key.Close()
                }
            }
        }
        finally {
            $base.Close()
        }
    }

    if ($remaining.Count -gt 0) {
        throw "Command Processor AutoRun is still set in: $($remaining -join ', '). Run this script from an elevated 64-bit PowerShell session."
    }
}

try {
    if ($OnWindows) {
        # system() starts %ComSpec%, which a per-user environment variable can override.
        $env:ComSpec = Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'cmd.exe'

        foreach ($subKey in $UserAutoRunKeyChain) {
            [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey).Close()
            Set-UserKeyIntegrityLabel -SubKey $subKey -Label 'S:(ML;;NW;;;HI)'
        }
        Write-Host "HKCU\Software\Microsoft\Command Processor and its parent keys are read-only to non-elevated processes until the package installs finish. If this run is interrupted, run install.ps1 again to restore them." -ForegroundColor Cyan
    }

    foreach ($autoRunKeyPath in $AutoRunKeyPaths) {
        if ($null -ne (Get-ItemProperty -Path $autoRunKeyPath -Name AutoRun -ErrorAction SilentlyContinue)) {
            Write-Warning "Removing the cmd.exe AutoRun value from $autoRunKeyPath so it cannot run with administrator rights."
            Write-Log "Removing AutoRun from $autoRunKeyPath"
        }
        Remove-ItemProperty -Path $autoRunKeyPath -Name AutoRun -ErrorAction SilentlyContinue
    }

    if ($OnWindows) {
        Assert-NoCommandProcessorAutoRun
    }
}
catch {
    Write-Log "ABORT: unable to remove cmd.exe AutoRun before installing packages: $($_.Exception.Message)"
    if ($OnWindows) {
        Unlock-UserAutoRunKeyChain
    }
    throw "Refusing to install packages while cmd.exe AutoRun could run with administrator rights. $($_.Exception.Message)"
}

# 1. Install Chocolatey (run in an elevated PowerShell)
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 2. Open a NEW shell (so choco is on PATH), then install packages below.
#    Tip: you can install everything in one go with:
#    choco install -y googlechrome rclone vim rsync gh git 7zip ...
#    The -y flag skips confirmation prompts, useful for a full bootstrap run.
#    Prefer running this script: a bare elevated choco install skips the
#    AutoRun protection above, and installers like vim's run cmd.exe /c.

$packages = @(
    # -----------------------------------------------------------
    # My seed list
    # -----------------------------------------------------------
    'googlechrome',
    'rclone',
    'vim',
    'rsync',
    'gh',
    'git',

    # -----------------------------------------------------------
    # Core CLI / shell essentials (pairs naturally with git/gh/vim)
    # -----------------------------------------------------------
    '7zip',                 # archive tool, used everywhere
    'curl',                 # Windows ships one, but choco's is often newer
    'wget',
    'jq',                   # JSON processor, invaluable with gh/curl
    'sudo',                 # gsudo-style elevation from any shell
    'grep',
    'sed',
    'less',
    'winrar',

    # -----------------------------------------------------------
    # Terminal / shell environment
    # -----------------------------------------------------------
    'microsoft-windows-terminal',
    'powershell-core',      # pwsh (v7+), alongside Windows PowerShell
    'starship',             # cross-shell prompt, works well with git

    # -----------------------------------------------------------
    # Editors / IDEs
    # -----------------------------------------------------------
    'vscode',
    'notepadplusplus',

    # -----------------------------------------------------------
    # Dev runtimes & package managers
    # (skip any you don't personally use)
    # -----------------------------------------------------------
    'nodejs-lts',
    'python',
    'openjdk',
    'golang',
    'rust',

    # -----------------------------------------------------------
    # Containers / virtualization
    # -----------------------------------------------------------
    'docker-desktop',

    # -----------------------------------------------------------
    # Cloud & infra CLIs
    # -----------------------------------------------------------
    'awscli',
    'azure-cli',
    'terraform',
    'kubernetes-cli',       # kubectl

    # -----------------------------------------------------------
    # Networking / remote access
    # -----------------------------------------------------------
    'putty',                # ssh/telnet client + puttygen
    'winscp',               # GUI sftp/scp, complements rsync
    'openssh',              # ssh/scp/sftp client+server if not already present
    'mobaxterm',            # alternative all-in-one terminal + X server
    'nmap',                 # network scanner 

    # -----------------------------------------------------------
    # API / DB tooling
    # -----------------------------------------------------------
    'postman',
    'dbeaver',              # universal DB GUI client

    # -----------------------------------------------------------
    # System utilities (Sysinternals-adjacent, general QoL)
    # -----------------------------------------------------------
    'powertoys',            # not enough people know about this. It's the best thing on windows no-one knows about! Window snapping, FancyZones, PowerToys Run, etc.
    'sysinternals',         # full Sysinternals suite - these are still going strong after all these years
    'everything',           # instant file search
    'treesizefree',         # disk usage visualizer

    # -----------------------------------------------------------
    # Browsers (beyond Chrome, useful for cross-browser testing)
    # -----------------------------------------------------------
    'firefox',
    'microsoft-edge',

    # -----------------------------------------------------------
    # Media / misc
    # -----------------------------------------------------------
    'vlc',
    'ffmpeg',
    'greenshot',            # lightweight screenshot tool

    # -----------------------------------------------------------
    # Fonts (nice with Windows Terminal / vim / vscode)
    # -----------------------------------------------------------
    'cascadia-code-nerd-font'
)

$failedPackages = New-Object System.Collections.Generic.List[string]

Write-Host "Installing $($packages.Count) package(s)..." -ForegroundColor Cyan
Write-Log "Installing $($packages.Count) package(s): $($packages -join ', ')"

foreach ($pkg in $packages) {
    Write-Host "==> Installing $pkg" -ForegroundColor Yellow
    Write-Log "BEGIN install: $pkg"

    $output = & choco install -y $pkg 2>&1
    $exitCode = $LASTEXITCODE

    if ($UseLogging) {
        Add-Content -Path $LogPath -Value $output
    }

    if ($exitCode -eq 0) {
        Write-Host "✅ $pkg installed successfully" -ForegroundColor Green
        Write-Log "SUCCESS install: $pkg (exit code $exitCode)"
    }
    else {
        Write-Warning "❌ $pkg failed (exit code $exitCode)"
        Write-Log "FAIL install: $pkg (exit code $exitCode)"
        $failedPackages.Add($pkg) | Out-Null
    }
}

if ($OnWindows) {
    Unlock-UserAutoRunKeyChain
}

Write-Host ""
Write-Host "Install run complete." -ForegroundColor Cyan
Write-Log "Install run complete. Failures: $($failedPackages.Count)"

if ($failedPackages.Count -gt 0) {
    $failedList = $failedPackages -join ', '
    Write-Warning "Some package installs failed: $failedList"
    Write-Host "Review output above and retry failed packages individually." -ForegroundColor Yellow

    if ($UseLogging) {
        Write-Host "Log file: $LogPath" -ForegroundColor Yellow
        Write-Log "Failed packages: $failedList"
    }
}
else {
    Write-Host "✅ All packages installed successfully." -ForegroundColor Green
    if ($UseLogging) {
        Write-Host "Log file: $LogPath" -ForegroundColor Green
    }
}
