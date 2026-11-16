# Fails while install.ps1 installs openssh by id into a temp directory the
# logged-on user can write. Passes once that install no longer publishes
# replaced ssh, scp, and sftp binaries.
#
# Run from the repository root:
#   pwsh -NoProfile -File tests/OpenSSHTempPath.Tests.ps1
#
# The fixtures are the community packages Chocolatey 2.7.5 selects for
# `choco install openssh` (stable 8.0.0.1) and `choco install openssh --pre`
# (9.5.0-beta20240403). Their chocolateyinstall.ps1 files are unmodified.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$InstallScript = Join-Path $RepoRoot 'install.ps1'
$FixtureRoot = Join-Path $PSScriptRoot 'fixtures'

$StablePackage = '8.0.0.1'
$PrereleasePackage = '9.5.0-beta20240403'
$AttackerMarker = [Text.Encoding]::ASCII.GetBytes('LOGGED-ON-USER-REPLACEMENT')
$SharedExecutables = @(
    'ssh.exe',
    'scp.exe',
    'sftp.exe',
    'sftp-server.exe',
    'ssh-add.exe',
    'ssh-agent.exe',
    'ssh-keygen.exe',
    'ssh-keyscan.exe',
    'ssh-shellhost.exe',
    'sshd.exe'
)

$script:Failures = New-Object System.Collections.Generic.List[string]
$global:OpenSshInvocations = @()
$global:TestMachinePath = 'C:\Windows\system32'
$global:TestMachineTerm = $null
$global:UserProfile = $null
$global:AttackerReplacements = 0

function Add-Failure {
    param([string]$Name, [string]$Message)
    $script:Failures.Add("${Name}: $Message") | Out-Null
    Write-Host "FAIL $Name"
    Write-Host "  $Message"
}

function ConvertTo-PortablePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }
    return (($Path -replace '\\', '/') -replace '/+', '/')
}

function Test-UnderUserProfile {
    param([string]$Path)
    $profile = ConvertTo-PortablePath $global:UserProfile
    $candidate = ConvertTo-PortablePath $Path
    if ([string]::IsNullOrWhiteSpace($profile) -or [string]::IsNullOrWhiteSpace($candidate)) {
        return $false
    }
    $profile = $profile.TrimEnd('/')
    return ($candidate -eq $profile) -or $candidate.StartsWith($profile + '/', [StringComparison]::Ordinal)
}

function Update-LoggedOnUserReplacement {
    # The logged-on user's filtered token can write the user profile, which is
    # where an elevated same-user process leaves TEMP. It cannot write a
    # directory outside that profile.
    if ([string]::IsNullOrWhiteSpace($global:UserProfile) -or -not (Test-Path -LiteralPath $global:UserProfile)) {
        return
    }
    $executables = Get-ChildItem -LiteralPath $global:UserProfile -Recurse -File -Filter *.exe -ErrorAction SilentlyContinue
    foreach ($executable in $executables) {
        if (-not (Test-UnderUserProfile $executable.FullName)) {
            continue
        }
        try {
            [IO.File]::WriteAllBytes($executable.FullName, $AttackerMarker)
            $global:AttackerReplacements++
        }
        catch {
            # A directory the user cannot write is the protected case.
        }
    }
}

function global:Set-ExecutionPolicy {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$ExecutionPolicy,
        [string]$Scope,
        [switch]$Force
    )
}

function global:choco {
    $global:LASTEXITCODE = 0
    if (@($args) -contains 'openssh') {
        $global:OpenSshInvocations += [pscustomobject]@{
            Arguments = @($args)
            Temp      = $env:TEMP
            Tmp       = $env:TMP
        }
    }
}

function global:Get-CimInstance {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$ClassName)
    return [pscustomobject]@{ Version = '10.0.26200' }
}

function global:Get-WmiObject {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Class)
    # chocolateyinstall.ps1 queries Win32_Service after unzip and before copy.
    Update-LoggedOnUserReplacement
    return @()
}

function global:Get-Process {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    return $null
}

function global:Get-Service {
    [CmdletBinding()]
    param([Parameter(Position = 0)][string]$Name)
    return $null
}

function global:Get-FileHash {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [string]$Algorithm = 'SHA256'
    )
    $hash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath (ConvertTo-PortablePath $Path) -Algorithm $Algorithm
    # Replacing after the hash is the check-then-use the package's zip checksum misses.
    Update-LoggedOnUserReplacement
    return $hash
}

function global:Get-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [Parameter(Position = 1)][string]$Name
    )
    if ($Path -like 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion*') {
        if ($Name -eq 'ProductName') {
            return [pscustomobject]@{ ProductName = 'Windows 11 Pro' }
        }
        if ($Name -eq 'EditionID' -or $Name -eq 'EditionId') {
            return [pscustomobject]@{ EditionId = 'Professional' }
        }
    }
    if ($Path -like '*Session Manager*Environment*') {
        return [pscustomobject]@{
            Path = $global:TestMachinePath
            TERM = $global:TestMachineTerm
        }
    }
    return Microsoft.PowerShell.Management\Get-ItemProperty @PSBoundParameters
}

function global:Set-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$Path,
        [string]$Name,
        $Value
    )
    if ($Path -like '*Session Manager*Environment*') {
        if ($Name -eq 'PATH' -or $Name -eq 'Path') {
            $global:TestMachinePath = [string]$Value
        }
        elseif ($Name -eq 'TERM') {
            $global:TestMachineTerm = [string]$Value
        }
        return
    }
    Microsoft.PowerShell.Management\Set-ItemProperty @PSBoundParameters
}

function global:Install-ChocolateyPath {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)][string]$PathToInstall,
        [Parameter(Position = 1)][string]$PathType = 'User'
    )
    $entries = @($global:TestMachinePath -split ';' | Where-Object { $_ -ne '' })
    $already = $false
    foreach ($entry in $entries) {
        if ($entry.TrimEnd('\') -eq $PathToInstall.TrimEnd('\')) {
            $already = $true
        }
    }
    if (-not $already) {
        $entries += $PathToInstall
        $global:TestMachinePath = ($entries -join ';')
    }
}

function Invoke-BootstrapCapture {
    $global:OpenSshInvocations = @()
    $source = Get-Content -LiteralPath $InstallScript -Raw
    $download = "iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))"
    if ($source.Contains($download)) {
        # The bootstrap downloads and executes Chocolatey. The openssh install below it is the path under test.
        $source = $source.Replace($download, '$null')
    }
    $temporaryScript = Join-Path $global:WorkRoot 'install-under-test.ps1'
    Set-Content -LiteralPath $temporaryScript -Value $source -Encoding utf8
    $previousLocation = Get-Location
    try {
        & $temporaryScript | Out-Null
    }
    finally {
        Set-Location $previousLocation
    }
}

function Resolve-SelectedPackage {
    param([string[]]$Arguments)
    $prerelease = $false
    $version = $null
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = [string]$Arguments[$i]
        if ($argument -in @('--pre', '--prerelease', '-pre')) {
            $prerelease = $true
            continue
        }
        if ($argument -match '^(?:--version=|--ver=)(.+)$') {
            $version = $Matches[1]
            continue
        }
        if ($argument -in @('--version', '--ver', '-version') -and ($i + 1) -lt $Arguments.Count) {
            $version = [string]$Arguments[$i + 1]
            $i++
        }
    }
    if ([string]::IsNullOrWhiteSpace($version)) {
        if ($prerelease) {
            return $PrereleasePackage
        }
        return $StablePackage
    }
    return $version
}

function New-WindowsSevenZipAdapter {
    param([string]$ToolsDirectory)
    $adapter = Join-Path $ToolsDirectory '7z.exe'
    $python = @'
#!/usr/bin/env python3
import os, sys
args = [argument.replace("\\", "/") for argument in sys.argv[1:]]
os.execvp("7z", ["7z", *args])
'@
    Set-Content -LiteralPath $adapter -Value $python -Encoding ascii
    & chmod +x $adapter
}

function Get-ZipEntryBytes {
    param([string]$ZipPath, [string]$EntryName)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $archive = [IO.Compression.ZipFile]::OpenRead((ConvertTo-PortablePath $ZipPath))
    try {
        $entry = $archive.GetEntry($EntryName)
        if ($null -eq $entry) {
            throw "Missing $EntryName in $ZipPath"
        }
        $stream = $entry.Open()
        try {
            $buffer = New-Object byte[] $entry.Length
            $read = 0
            while ($read -lt $buffer.Length) {
                $count = $stream.Read($buffer, $read, $buffer.Length - $read)
                if ($count -le 0) { break }
                $read += $count
            }
            return $buffer
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $archive.Dispose()
    }
}

function Test-SameBytes {
    param([byte[]]$Left, [byte[]]$Right)
    if ($null -eq $Left -or $null -eq $Right -or $Left.Length -ne $Right.Length) {
        return $false
    }
    for ($i = 0; $i -lt $Left.Length; $i++) {
        if ($Left[$i] -ne $Right[$i]) {
            return $false
        }
    }
    return $true
}

function Invoke-PackageInstall {
    param(
        [string]$PackageVersion,
        [string]$ProcessTemp
    )
    $fixture = Join-Path $FixtureRoot "openssh-$PackageVersion"
    if (-not (Test-Path -LiteralPath $fixture)) {
        return [pscustomobject]@{
            KnownPackage = $false
            Error        = $null
            Tools        = $null
        }
    }
    $packageRoot = Join-Path $global:WorkRoot "pkg-$PackageVersion"
    if (Test-Path -LiteralPath $packageRoot) {
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $packageRoot | Out-Null
    Copy-Item -Path (Join-Path $fixture '*') -Destination $packageRoot -Recurse -Force
    $tools = Join-Path $packageRoot 'tools'
    New-WindowsSevenZipAdapter -ToolsDirectory $tools
    # Windows environment variables are case-insensitive. The package reads $env:temp.
    foreach ($name in @('TEMP', 'temp', 'TMP', 'tmp')) {
        Set-Item -Path "Env:$name" -Value $ProcessTemp
    }
    $previousLocation = Get-Location
    $packageError = $null
    try {
        & (Join-Path $tools 'chocolateyinstall.ps1') | Out-Null
    }
    catch {
        $packageError = $_
    }
    finally {
        Set-Location $previousLocation
    }
    return [pscustomobject]@{
        KnownPackage = $true
        Error        = $packageError
        Tools        = $tools
    }
}

function Get-PublishedExecutable {
    param([string]$ProgramFiles, [string]$Name)
    $candidates = @(
        (Join-Path (ConvertTo-PortablePath "$ProgramFiles\OpenSSH-Win64") $Name),
        (Join-Path (ConvertTo-PortablePath "$ProgramFiles/OpenSSH-Win64") $Name)
    )
    foreach ($entry in @($global:TestMachinePath -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        $portableEntry = ConvertTo-PortablePath $entry
        if ($portableEntry -match '^[A-Za-z]:') { continue }
        $candidates += (Join-Path $portableEntry $Name)
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Get-Item -LiteralPath $candidate).FullName
        }
    }
    return $null
}

function Test-OpenSSHInstallDoesNotPublishReplacedTools {
    param([string]$Name)
    $global:AttackerReplacements = 0
    $global:TestMachinePath = 'C:\Windows\system32'
    $global:TestMachineTerm = $null

    Invoke-BootstrapCapture
    if ($global:OpenSshInvocations.Count -eq 0) {
        Write-Host "PASS $Name (openssh is not installed)"
        return
    }

    $invocation = $global:OpenSshInvocations[-1]
    $packageVersion = Resolve-SelectedPackage -Arguments $invocation.Arguments
    $processTemp = $invocation.Temp
    if ([string]::IsNullOrWhiteSpace($processTemp)) {
        Add-Failure $Name 'choco install openssh ran with TEMP unset, so the package falls back to a world-writable temp.'
        return
    }

    $result = Invoke-PackageInstall -PackageVersion $packageVersion -ProcessTemp $processTemp
    if (-not $result.KnownPackage) {
        if (Test-UnderUserProfile $processTemp) {
            Add-Failure $Name "choco install openssh selects package $packageVersion with TEMP '$processTemp' inside the logged-on user profile. This test has no installer for that version that avoids the temp copy."
        }
        else {
            Write-Host "PASS $Name (openssh $packageVersion temp is outside the logged-on user profile)"
        }
        return
    }

    $zipPath = Join-Path $result.Tools 'OpenSSH-Win64.zip'
    $zipHash = Microsoft.PowerShell.Utility\Get-FileHash -LiteralPath $zipPath -Algorithm SHA1
    $installText = Get-Content -LiteralPath (Join-Path $result.Tools 'chocolateyinstall.ps1') -Raw
    $expectedHash = [regex]::Match($installText, "checksum64\s*=\s*'([^']+)'").Groups[1].Value
    if ($zipHash.Hash -ne $expectedHash) {
        Add-Failure $Name "package zip SHA1 $($zipHash.Hash) does not match checksum64 $expectedHash, so this run did not exercise the package checksum."
        return
    }

    $mismatched = New-Object System.Collections.Generic.List[string]
    foreach ($executable in $SharedExecutables) {
        $published = Get-PublishedExecutable -ProgramFiles $env:ProgramFiles -Name $executable
        if ([string]::IsNullOrWhiteSpace($published)) {
            $mismatched.Add("$executable was not published") | Out-Null
            continue
        }
        $publishedBytes = [IO.File]::ReadAllBytes($published)
        $originalBytes = Get-ZipEntryBytes -ZipPath $zipPath -EntryName "OpenSSH-Win64/$executable"
        if (Test-SameBytes $publishedBytes $AttackerMarker) {
            $mismatched.Add("$executable on the install path is the logged-on user's replacement (zip SHA1 $($zipHash.Hash) still matches)") | Out-Null
        }
        elseif (-not (Test-SameBytes $publishedBytes $originalBytes)) {
            $mismatched.Add("$executable on the install path differs from the zip entry") | Out-Null
        }
    }

    $pathHasTarget = $false
    foreach ($entry in @($global:TestMachinePath -split ';')) {
        if ($entry -like '*OpenSSH-Win64*') {
            $pathHasTarget = $true
        }
    }

    if ($mismatched.Count -gt 0) {
        $detail = ($mismatched -join '; ')
        Add-Failure $Name "$detail. Machine PATH is '$($global:TestMachinePath)'. Replacements written: $($global:AttackerReplacements). Package error: $($result.Error)"
        return
    }
    if (-not $pathHasTarget) {
        Add-Failure $Name "The OpenSSH tools match the zip, but the machine PATH was not given the OpenSSH-Win64 directory. PATH='$($global:TestMachinePath)'."
        return
    }
    Write-Host "PASS $Name"
}

$global:WorkRoot = Join-Path ([IO.Path]::GetTempPath()) ("openssh-temp-path-" + [guid]::NewGuid().ToString('n'))
New-Item -ItemType Directory -Path $global:WorkRoot | Out-Null
$global:UserProfile = Join-Path $global:WorkRoot 'Users\Administrator'
$userTemp = Join-Path $global:UserProfile 'AppData\Local\Temp'
New-Item -ItemType Directory -Path (ConvertTo-PortablePath $userTemp) -Force | Out-Null
$programFiles = Join-Path $global:WorkRoot 'Program Files'
New-Item -ItemType Directory -Path (ConvertTo-PortablePath $programFiles) -Force | Out-Null

$env:USERPROFILE = $global:UserProfile
foreach ($name in @('TEMP', 'temp', 'TMP', 'tmp')) {
    Set-Item -Path "Env:$name" -Value $userTemp
}
$env:ProgramFiles = $programFiles
$env:ProgramData = Join-Path $global:WorkRoot 'ProgramData'
$env:windir = Join-Path $global:WorkRoot 'Windows'
New-Item -ItemType Directory -Path (ConvertTo-PortablePath $env:ProgramData) -Force | Out-Null
New-Item -ItemType Directory -Path (ConvertTo-PortablePath $env:windir) -Force | Out-Null

Write-Host "TEST Unpinned openssh install does not publish logged-on user replacements of ssh, scp, and sftp"
Test-OpenSSHInstallDoesNotPublishReplacedTools -Name 'Unpinned openssh install does not publish logged-on user replacements of ssh, scp, and sftp'

if ($script:Failures.Count -gt 0) {
    Write-Host ""
    Write-Host "$($script:Failures.Count) test(s) failed."
    exit 1
}

Write-Host ""
Write-Host "All OpenSSH temp-path tests passed."
exit 0
