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

# The Chocolatey bootstrap and package scripts unpack into TEMP and then run or
# copy what they find there with this session's elevated rights. The logged-on
# user's TEMP (or any directory they can write) lets that user swap the files in
# between, so every install uses a directory only SYSTEM and Administrators can
# write.
function New-ProtectedTempDirectory {
    $ErrorActionPreference = 'Stop'
    $name = "choco-installs-{0}" -f [guid]::NewGuid().ToString('n')

    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
        # mktemp creates the directory 0700 in one step.
        $path = & mktemp -d (Join-Path -Path ([IO.Path]::GetTempPath()) -ChildPath "$name-XXXXXXXX")
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($path)) {
            throw "mktemp failed to create a private temp directory."
        }
        return $path
    }

    # Resolved through the known-folder API: $env:ProgramData can be overridden
    # from the user's own environment.
    $parent = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($parent)) {
        throw "Unable to resolve the ProgramData folder."
    }
    $path = Join-Path -Path $parent -ChildPath $name

    $systemSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::LocalSystemSid, $null)
    $adminsSid = New-Object System.Security.Principal.SecurityIdentifier([System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid, $null)
    $allowedSids = @($systemSid.Value, $adminsSid.Value)

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetOwner($adminsSid)
    $security.SetAccessRuleProtection($true, $false)
    foreach ($sid in @($systemSid, $adminsSid)) {
        $rule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sid,
            [System.Security.AccessControl.FileSystemRights]::FullControl,
            [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit',
            [System.Security.AccessControl.PropagationFlags]::None,
            [System.Security.AccessControl.AccessControlType]::Allow)
        $security.AddAccessRule($rule)
    }

    # The owner and DACL are applied by the create call itself, so there is no
    # window in which the directory carries ProgramData's inherited
    # Users-can-create ACEs. Creating it with an Administrators owner also fails
    # outside an elevated session.
    # Windows PowerShell keeps these types in mscorlib.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -AssemblyName System.IO.FileSystem.AccessControl
    }
    $aclExtensions = 'System.IO.FileSystemAclExtensions' -as [type]
    if ($null -ne $aclExtensions) {
        $aclExtensions::Create((New-Object System.IO.DirectoryInfo($path)), $security)
    }
    else {
        $null = [System.IO.Directory]::CreateDirectory($path, $security)
    }

    # Both create calls succeed silently on an existing directory, so refuse
    # anything that does not carry exactly the descriptor requested above.
    $acl = Get-Acl -LiteralPath $path
    $owner = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
    if ($owner -notin $allowedSids) {
        throw "Temp directory '$path' is owned by $owner, not SYSTEM or Administrators."
    }
    if (-not $acl.AreAccessRulesProtected) {
        throw "Temp directory '$path' inherits permissions from its parent."
    }
    foreach ($rule in $acl.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or $rule.IdentityReference.Value -notin $allowedSids) {
            throw "Temp directory '$path' grants access to $($rule.IdentityReference.Value)."
        }
    }

    return $path
}

function Use-ProtectedTemp {
    $env:TEMP = $ProtectedTemp
    $env:TMP = $ProtectedTemp
}

# The bootstrap and choco inherit this process environment, including values a
# medium-integrity process put in the user environment. Keep Chocolatey's own
# location variables on the machine value for the duration of the installs.
$Script:HadChocolateyInstall = $false
$Script:OriginalChocolateyInstall = $null
$Script:HadChocolateyDownloadUrl = $false
$Script:OriginalChocolateyDownloadUrl = $null

function Save-ChocolateyProcessVariables {
    $Script:HadChocolateyInstall = Test-Path -Path Env:ChocolateyInstall
    if ($Script:HadChocolateyInstall) {
        $Script:OriginalChocolateyInstall = $env:ChocolateyInstall
    }
    $Script:HadChocolateyDownloadUrl = Test-Path -Path Env:chocolateyDownloadUrl
    if ($Script:HadChocolateyDownloadUrl) {
        $Script:OriginalChocolateyDownloadUrl = $env:chocolateyDownloadUrl
    }
}

function Use-MachineChocolateyVariables {
    foreach ($name in @('ChocolateyInstall', 'chocolateyDownloadUrl')) {
        $machine = $null
        try {
            $machine = [System.Environment]::GetEnvironmentVariable($name, 'Machine')
        }
        catch {
            $machine = $null
        }
        if ([string]::IsNullOrEmpty($machine)) {
            if (Test-Path -Path "Env:$name") {
                Remove-Item -Path "Env:$name"
            }
        }
        else {
            Set-Item -Path "Env:$name" -Value $machine
        }
    }
}

function Restore-ChocolateyProcessVariables {
    if ($Script:HadChocolateyInstall) {
        $env:ChocolateyInstall = $Script:OriginalChocolateyInstall
    }
    elseif (Test-Path -Path Env:ChocolateyInstall) {
        Remove-Item -Path Env:ChocolateyInstall
    }
    if ($Script:HadChocolateyDownloadUrl) {
        $env:chocolateyDownloadUrl = $Script:OriginalChocolateyDownloadUrl
    }
    elseif (Test-Path -Path Env:chocolateyDownloadUrl) {
        Remove-Item -Path Env:chocolateyDownloadUrl
    }
}

function Restore-InstallEnvironment {
    if ($null -ne $OriginalTemp) {
        $env:TEMP = $OriginalTemp
    }
    elseif (Test-Path -Path Env:TEMP) {
        Remove-Item -Path Env:TEMP
    }
    if ($null -ne $OriginalTmp) {
        $env:TMP = $OriginalTmp
    }
    elseif (Test-Path -Path Env:TMP) {
        Remove-Item -Path Env:TMP
    }
    if (-not [string]::IsNullOrWhiteSpace($ProtectedTemp) -and (Test-Path -LiteralPath $ProtectedTemp)) {
        Remove-Item -LiteralPath $ProtectedTemp -Recurse -Force -ErrorAction SilentlyContinue
    }
    Restore-ChocolateyProcessVariables
}

function Test-PipelineStop {
    param($ErrorRecord)
    $exception = $ErrorRecord.Exception
    $stopped = $ErrorRecord.FullyQualifiedErrorId -eq 'PipelineStopped'
    while ($null -ne $exception -and -not $stopped) {
        if ($exception -is [System.Management.Automation.PipelineStoppedException] -or $exception -is [System.OperationCanceledException]) {
            $stopped = $true
        }
        $exception = $exception.InnerException
    }
    return $stopped
}

$OriginalTemp = $env:TEMP
$OriginalTmp = $env:TMP
try {
    $ProtectedTemp = New-ProtectedTempDirectory
}
catch {
    Write-Log "ABORT: unable to create a protected temp directory: $($_.Exception.Message)"
    throw "Unable to create a temp directory that only SYSTEM and Administrators can write. Run this script from an elevated PowerShell session. $($_.Exception.Message)"
}
Write-Log "Using protected temp directory: $ProtectedTemp"
Save-ChocolateyProcessVariables

try {
    # The trap covers the bootstrap statement. Each package has its own catch,
    # because continue here resumes after the whole foreach, not the next package.
    # A pipeline stop still leaves the block so finally can restore TEMP.
    trap {
        if (Test-PipelineStop $_) {
            throw
        }
        Write-Warning "Continuing after an error: $($_.Exception.Message)"
        Write-Log "CONTINUE after error: $($_.Exception.Message)"
        continue
    }

Use-ProtectedTemp
Use-MachineChocolateyVariables

# 1. Install Chocolatey (run in an elevated PowerShell)
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 2. Open a NEW shell (so choco is on PATH), then install packages below.
#    Install through this script rather than a bare `choco install` in your
#    shell: the loop below points TEMP at the protected directory for every
#    package. The -y flag it passes skips confirmation prompts.

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
    try {
        Write-Host "==> Installing $pkg" -ForegroundColor Yellow
        Write-Log "BEGIN install: $pkg"

        # Chocolatey's setup can reload session variables from the registry, which
        # would put TEMP back on the user's profile and could bring back a user
        # ChocolateyInstall or download URL.
        Use-ProtectedTemp
        Use-MachineChocolateyVariables
        # Chocolatey's bootstrap often leaves ErrorAction Stop. Under Stop,
        # 2>&1 turns choco's own stderr into a terminating error on Windows
        # PowerShell 5.1 even when the install succeeded.
        $previousErrorAction = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $output = & choco install -y $pkg 2>&1
            $exitCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousErrorAction
        }

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
    catch {
        if (Test-PipelineStop $_) {
            throw
        }
        Write-Warning "❌ $pkg failed: $($_.Exception.Message)"
        Write-Log "FAIL install: $pkg ($($_.Exception.Message))"
        $failedPackages.Add($pkg) | Out-Null
    }
}
}
finally {
    try {
        Restore-InstallEnvironment
    }
    catch {
        Write-Warning "Unable to restore TEMP or remove the protected temp directory. Error: $($_.Exception.Message)"
        Write-Log "FAIL restore install environment: $($_.Exception.Message)"
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
