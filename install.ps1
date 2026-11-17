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
# value or rename/replace those keys. The HKCU Command Processor key is replaced
# so a handle opened before the run cannot write through it. Saved AutoRun
# values and the user ComSpec value are restored from a finally block, including
# when the run is stopped, and the labels are removed there too.
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

    const int HKEY_CURRENT_USER = unchecked((int)0x80000001);
    const int KEY_QUERY_VALUE = 0x0001;
    const int DELETE = 0x00010000;
    const int REG_OPTION_OPEN_LINK = 0x0008;
    const int REG_LINK = 6;

    // Opening a registry link without this option follows it and would delete the target.
    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegOpenKeyEx(IntPtr key, string subKey, int options, int desired, out IntPtr result);

    [DllImport("advapi32.dll", CharSet = CharSet.Unicode)]
    static extern int RegQueryValueEx(IntPtr key, string name, IntPtr reserved, out int type, IntPtr data, ref int length);

    [DllImport("ntdll.dll")]
    static extern int NtDeleteKey(IntPtr key);

    [DllImport("advapi32.dll")]
    static extern int RegCloseKey(IntPtr key);

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

    public static bool IsSymbolicLink(string subKey)
    {
        IntPtr handle;
        int status = RegOpenKeyEx(new IntPtr(HKEY_CURRENT_USER), subKey, REG_OPTION_OPEN_LINK, KEY_QUERY_VALUE, out handle);
        if (status != 0) return false;
        try
        {
            int type = 0;
            int length = 0;
            // A null buffer returns ERROR_MORE_DATA (234) when the value exists, with the type filled in.
            status = RegQueryValueEx(handle, "SymbolicLinkValue", IntPtr.Zero, out type, IntPtr.Zero, ref length);
            return (status == 0 || status == 234) && type == REG_LINK;
        }
        finally { RegCloseKey(handle); }
    }

    // Deletes the link key itself. .NET DeleteSubKey follows the link.
    public static void DeleteSymbolicLink(string subKey)
    {
        IntPtr handle;
        int status = RegOpenKeyEx(new IntPtr(HKEY_CURRENT_USER), subKey, REG_OPTION_OPEN_LINK, DELETE, out handle);
        if (status != 0) throw new Win32Exception(status);
        try
        {
            status = NtDeleteKey(handle);
            if (status != 0) throw new Win32Exception("Deleting the registry link failed with status 0x" + status.ToString("X8"));
        }
        finally { RegCloseKey(handle); }
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

# Saved before AutoRun is removed and written back from the finally block, including
# when the run is stopped. The value itself is logged only if the restore fails.
$Script:SavedAutoRunValues = New-Object System.Collections.Generic.List[object]
$Script:UserComSpecSuspended = $false
$Script:HadUserComSpec = $false
$Script:SavedUserComSpec = $null
$Script:ReplacedCommandProcessorLink = $false

function Save-CommandProcessorAutoRunValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $property = Get-ItemProperty -Path $Path -Name AutoRun -ErrorAction SilentlyContinue
    if ($null -eq $property) {
        return
    }

    $value = $property.AutoRun
    $kind = [Microsoft.Win32.RegistryValueKind]::String
    $key = Get-Item -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $key -and $null -ne $key.PSObject.Methods['GetValueKind']) {
        try {
            $kind = $key.GetValueKind('AutoRun')
            $raw = $key.GetValue('AutoRun', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            if ($null -ne $raw) {
                $value = $raw
            }
        }
        catch {
            Write-Warning "Could not read the kind of the AutoRun value at $Path. It will be restored as a string."
            Write-Log "WARN AutoRun kind unreadable at $Path; restoring as a string."
        }
        finally {
            if ($null -ne $key.PSObject.Methods['Close']) {
                $key.Close()
            }
        }
    }

    $Script:SavedAutoRunValues.Add([pscustomobject]@{
            Path  = $Path
            Kind  = $kind
            Value = $value
        }) | Out-Null
    Write-Warning "Temporarily removing the cmd.exe AutoRun value from $Path so it cannot run with administrator rights. It will be restored when this script ends."
    Write-Log "Temporarily removing AutoRun from $Path; it will be restored when the script ends."
}

function Restore-CommandProcessorAutoRunValues {
    # @() on List[object] throws "Argument types do not match" under StrictMode.
    $pending = New-Object System.Collections.Generic.List[object]
    foreach ($saved in $Script:SavedAutoRunValues) {
        $pending.Add($saved) | Out-Null
    }
    $Script:SavedAutoRunValues.Clear()
    foreach ($saved in $pending) {
        try {
            if (-not (Test-Path -LiteralPath $saved.Path)) {
                New-Item -Path $saved.Path -Force -ErrorAction Stop | Out-Null
            }
            $typeName = [string]$saved.Kind
            if ([string]::IsNullOrWhiteSpace($typeName) -or $typeName -eq 'Unknown' -or $typeName -eq 'None') {
                $typeName = 'String'
            }
            New-ItemProperty -Path $saved.Path -Name AutoRun -Value $saved.Value -PropertyType $typeName -Force -ErrorAction Stop | Out-Null
            Write-Log "Restored AutoRun at $($saved.Path)"
        }
        catch {
            $shown = $saved.Value
            if ($shown -is [byte[]]) {
                $shown = [System.BitConverter]::ToString([byte[]]$shown)
            }
            elseif ($shown -is [Array]) {
                $shown = $shown -join '|'
            }
            Write-Warning "Unable to restore cmd.exe AutoRun at $($saved.Path). Set it again to: $shown"
            Write-Log "FAIL restore AutoRun at $($saved.Path): $($_.Exception.Message). Previous value: $shown"
        }
    }
}

function Suspend-UserComSpec {
    # Chocolatey's environment refresh loads the User scope after this process,
    # which would replace the ComSpec pin. Hold the user value for the run and
    # label the key so a medium-integrity process cannot write it back.
    $Script:UserComSpecSuspended = $true
    $current = [System.Environment]::GetEnvironmentVariable('ComSpec', 'User')
    if (-not [string]::IsNullOrEmpty($current)) {
        $Script:SavedUserComSpec = $current
        $Script:HadUserComSpec = $true
        [System.Environment]::SetEnvironmentVariable('ComSpec', $null, 'User')
        Write-Warning "Temporarily removing the user ComSpec value so package installs cannot be redirected. It will be restored when this script ends."
        Write-Log "Temporarily removed the user ComSpec value; it will be restored when the script ends."
    }
    [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment').Close()
    Set-UserKeyIntegrityLabel -SubKey 'Environment' -Label 'S:(ML;;NW;;;HI)'
}

function Resume-UserComSpec {
    if (-not $Script:UserComSpecSuspended) {
        return
    }
    try {
        Set-UserKeyIntegrityLabel -SubKey 'Environment' -Label 'S:'
    }
    catch {
        Write-Warning "Unable to remove the integrity label from HKCU\Environment. Error: $($_.Exception.Message)"
        Write-Log "FAIL remove integrity label: HKCU\Environment"
    }
    if ($Script:HadUserComSpec) {
        try {
            [System.Environment]::SetEnvironmentVariable('ComSpec', $Script:SavedUserComSpec, 'User')
            Write-Log "Restored the user ComSpec value."
        }
        catch {
            Write-Warning "Unable to restore the user ComSpec value. Set it again to: $($Script:SavedUserComSpec)"
            Write-Log "FAIL restore user ComSpec: $($_.Exception.Message). Previous value: $($Script:SavedUserComSpec)"
        }
    }
    $Script:UserComSpecSuspended = $false
    $Script:HadUserComSpec = $false
    $Script:SavedUserComSpec = $null
}

function Protect-UserCommandProcessorKey {
    $relative = 'Software\Microsoft\Command Processor'
    $hive = [Microsoft.Win32.Registry]::CurrentUser

    # A link would send a later delete at the target. Replace the link itself.
    if ([RegistryIntegrityLabel]::IsSymbolicLink($relative)) {
        [RegistryIntegrityLabel]::DeleteSymbolicLink($relative)
        $hive.CreateSubKey($relative).Close()
        Set-UserKeyIntegrityLabel -SubKey $relative -Label 'S:(ML;;NW;;;HI)'
        $Script:ReplacedCommandProcessorLink = $true
        Write-Warning "Replaced the registry link at HKCU\$relative so an existing handle cannot set AutoRun."
        Write-Log "Replaced registry link: HKCU\$relative"
        return
    }

    $preserved = New-Object System.Collections.Generic.List[object]
    $existing = $hive.OpenSubKey($relative)
    if ($null -ne $existing) {
        try {
            if ($existing.GetSubKeyNames().Length -gt 0) {
                throw "HKCU\$relative has subkeys, so it cannot be replaced without deleting them."
            }
            foreach ($name in $existing.GetValueNames()) {
                if ($name -eq 'AutoRun') {
                    continue
                }
                $preserved.Add([pscustomobject]@{
                        Name  = $name
                        Kind  = $existing.GetValueKind($name)
                        Value = $existing.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                    }) | Out-Null
            }
        }
        finally {
            $existing.Close()
        }
        # Deletes the key object. Handles opened earlier fail with ERROR_KEY_DELETED.
        $hive.DeleteSubKey($relative, $true)
    }

    $created = $hive.CreateSubKey($relative)
    try {
        foreach ($item in $preserved) {
            if ($null -eq $item.Value) {
                continue
            }
            $created.SetValue($item.Name, $item.Value, $item.Kind)
        }
    }
    finally {
        $created.Close()
    }
    Set-UserKeyIntegrityLabel -SubKey $relative -Label 'S:(ML;;NW;;;HI)'
}

function Restore-InstallGuards {
    if ($OnWindows) {
        Unlock-UserAutoRunKeyChain
    }
    Restore-CommandProcessorAutoRunValues
    if ($OnWindows) {
        Resume-UserComSpec
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

        foreach ($subKey in @('Software', 'Software\Microsoft')) {
            [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($subKey).Close()
            Set-UserKeyIntegrityLabel -SubKey $subKey -Label 'S:(ML;;NW;;;HI)'
        }
        # Replace a link before any provider read, which would follow it.
        if ([RegistryIntegrityLabel]::IsSymbolicLink('Software\Microsoft\Command Processor')) {
            Protect-UserCommandProcessorKey
        }
        Suspend-UserComSpec
        Write-Host "HKCU\Software\Microsoft\Command Processor and its parent keys are read-only to non-elevated processes until the package installs finish. Existing AutoRun values are restored when the script ends, including if it is stopped early." -ForegroundColor Cyan
    }

    foreach ($autoRunKeyPath in $AutoRunKeyPaths) {
        Save-CommandProcessorAutoRunValue -Path $autoRunKeyPath
        Remove-ItemProperty -Path $autoRunKeyPath -Name AutoRun -ErrorAction SilentlyContinue
    }

    if ($OnWindows -and -not $Script:ReplacedCommandProcessorLink) {
        # After the value is saved: drop the key object so an already-open handle cannot write it back.
        Protect-UserCommandProcessorKey
    }

    if ($OnWindows) {
        Assert-NoCommandProcessorAutoRun
    }
}
catch {
    $reason = $_.Exception.Message
    Write-Log "ABORT: unable to remove cmd.exe AutoRun before installing packages: $reason"
    # A statement-terminating error here would skip the refusal and continue
    # into the package installs. Keep that error inside its own handler.
    try {
        Restore-InstallGuards
    }
    catch {
        Write-Warning "Unable to restore cmd.exe AutoRun after aborting the install. Error: $($_.Exception.Message)"
        Write-Log "FAIL restore after abort: $($_.Exception.Message)"
    }
    throw "Refusing to install packages while cmd.exe AutoRun could run with administrator rights. $reason"
}

try {
    # A statement-terminating error inside try would otherwise skip the rest of
    # this block. continue keeps the previous per-statement behaviour. Stopping
    # the pipeline (Ctrl+C) still leaves the block so finally can unlock.
    trap {
        $exception = $_.Exception
        $stopped = $_.FullyQualifiedErrorId -eq 'PipelineStopped'
        while ($null -ne $exception -and -not $stopped) {
            if ($exception -is [System.Management.Automation.PipelineStoppedException] -or $exception -is [System.OperationCanceledException]) {
                $stopped = $true
            }
            $exception = $exception.InnerException
        }
        if ($stopped) {
            throw
        }
        continue
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
    if ($OnWindows) {
        # A package script may have reloaded session variables. Pin this again
        # before the next installer starts cmd.exe.
        $env:ComSpec = Join-Path -Path ([System.Environment]::GetFolderPath('System')) -ChildPath 'cmd.exe'
    }
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
}
finally {
    try {
        Restore-InstallGuards
    }
    catch {
        Write-Warning "Unable to restore cmd.exe AutoRun or remove the integrity labels. Error: $($_.Exception.Message)"
        Write-Log "FAIL restore at end: $($_.Exception.Message)"
    }
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
