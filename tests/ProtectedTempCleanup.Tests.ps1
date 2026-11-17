# install.ps1 must point TEMP at its protected directory only while it runs,
# and must not keep a user ChocolateyInstall or download URL for that window.
param(
    [ValidateSet('all', 'success', 'stop', 'bootstrap')]
    [string]$Mode = 'all'
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$InstallScript = Join-Path $RepoRoot 'install.ps1'

function Invoke-InstallUnderTest {
    param(
        [string]$StopAt,
        [switch]$FailBootstrap
    )

    $observedPath = Join-Path ([System.IO.Path]::GetTempPath()) ("choco-temp-observed-{0}.txt" -f [guid]::NewGuid().ToString('n'))
    $env:CHOCO_TEST_OBSERVED = $observedPath
    $env:CHOCO_TEST_STOP_AT = $StopAt
    if ($FailBootstrap) {
        $env:CHOCO_TEST_BOOTSTRAP_FAIL = '1'
    }
    else {
        Remove-Item Env:CHOCO_TEST_BOOTSTRAP_FAIL -ErrorAction SilentlyContinue
    }

    $originalTemp = Join-Path ([System.IO.Path]::GetTempPath()) 'user-temp'
    $originalTmp = Join-Path ([System.IO.Path]::GetTempPath()) 'user-tmp'
    $env:TEMP = $originalTemp
    $env:TMP = $originalTmp
    $env:ChocolateyInstall = 'D:\writable\choco'
    $env:chocolateyDownloadUrl = 'https://example.invalid/choco.nupkg'

    function Set-ExecutionPolicy {
        param(
            [string]$ExecutionPolicy,
            [string]$Scope,
            [switch]$Force
        )
    }

    function New-Object {
        [CmdletBinding()]
        param(
            [Parameter(Position = 0)]
            [object]$TypeName,

            [Parameter(Position = 1)]
            [object[]]$ArgumentList,

            [switch]$ComObject
        )

        if ([string]$TypeName -eq 'System.Net.WebClient') {
            $client = [pscustomobject]@{}
            if ($env:CHOCO_TEST_BOOTSTRAP_FAIL -eq '1') {
                Add-Member -InputObject $client -MemberType ScriptMethod -Name DownloadString -Value {
                    param($Url)
                    throw 'bootstrap download failed'
                }
            }
            else {
                Add-Member -InputObject $client -MemberType ScriptMethod -Name DownloadString -Value {
                    param($Url)
                    return ''
                }
            }
            return $client
        }

        $forward = @{}
        if ($PSBoundParameters.ContainsKey('TypeName')) { $forward['TypeName'] = $TypeName }
        if ($PSBoundParameters.ContainsKey('ArgumentList')) { $forward['ArgumentList'] = $ArgumentList }
        if ($ComObject) { $forward['ComObject'] = $true }
        Microsoft.PowerShell.Utility\New-Object @forward
    }

    function choco {
        $package = $null
        for ($i = 0; $i -lt $args.Count; $i++) {
            if ([string]$args[$i] -eq '-y' -and ($i + 1) -lt $args.Count) {
                $package = [string]$args[$i + 1]
            }
        }
        $install = if ($null -eq $env:ChocolateyInstall) { '' } else { $env:ChocolateyInstall }
        $download = if ($null -eq $env:chocolateyDownloadUrl) { '' } else { $env:chocolateyDownloadUrl }
        $exists = if (Test-Path -LiteralPath $env:TEMP) { 'yes' } else { 'no' }
        Add-Content -LiteralPath $env:CHOCO_TEST_OBSERVED -Value ("{0}`t{1}`t{2}`t{3}`t{4}`t{5}" -f $package, $env:TEMP, $env:TMP, $install, $download, $exists)
        if ($env:CHOCO_TEST_STOP_AT -eq $package) {
            throw (New-Object System.Management.Automation.PipelineStoppedException)
        }
        $global:LASTEXITCODE = 0
    }

    $failed = $false
    try {
        . $InstallScript
    }
    catch {
        $failed = $true
        Write-Host "install ended: $($_.Exception.Message)"
    }

    [pscustomobject]@{
        Failed         = $failed
        OriginalTemp   = $originalTemp
        OriginalTmp    = $originalTmp
        Temp           = $env:TEMP
        Tmp            = $env:TMP
        ChocolateyInstall = $env:ChocolateyInstall
        DownloadUrl    = $env:chocolateyDownloadUrl
        Observed       = @(if (Test-Path -LiteralPath $observedPath) { Get-Content -LiteralPath $observedPath } else { @() })
    }
}

function Assert-ObservedUsesProtectedTemp {
    param($Result)
    if ($Result.Observed.Count -eq 0) {
        throw 'package loop did not run'
    }
    foreach ($line in $Result.Observed) {
        $parts = $line -split "`t", 6
        $package, $temp, $tmp, $install, $download, $exists = $parts
        if ($temp -eq $Result.OriginalTemp -or $tmp -eq $Result.OriginalTmp) {
            throw "package $package kept the user temp directory"
        }
        if ($temp -ne $tmp) {
            throw "package $package had TEMP and TMP pointing at different directories"
        }
        if (-not [string]::IsNullOrEmpty($install) -or -not [string]::IsNullOrEmpty($download)) {
            throw "package $package still saw ChocolateyInstall='$install' download='$download'"
        }
        if ($exists -ne 'yes') {
            throw "package $package recorded a temp directory that was already gone: $temp"
        }
    }
}

function Assert-CleanedUp {
    param($Result)
    if ($Result.Temp -ne $Result.OriginalTemp -or $Result.Tmp -ne $Result.OriginalTmp) {
        throw "TEMP/TMP were not restored (TEMP='$($Result.Temp)' TMP='$($Result.Tmp)')"
    }
    if ($Result.ChocolateyInstall -ne 'D:\writable\choco') {
        throw "ChocolateyInstall was not restored (value='$($Result.ChocolateyInstall)')"
    }
    if ($Result.DownloadUrl -ne 'https://example.invalid/choco.nupkg') {
        throw "chocolateyDownloadUrl was not restored (value='$($Result.DownloadUrl)')"
    }
    $protected = ($Result.Observed[0] -split "`t", 6)[1]
    if (Test-Path -LiteralPath $protected) {
        throw "protected temp directory was left behind: $protected"
    }
}

function Invoke-SuccessCase {
    $result = Invoke-InstallUnderTest
    if ($result.Failed) { throw 'successful install returned an error' }
    Assert-ObservedUsesProtectedTemp $result
    $packages = @($result.Observed | ForEach-Object { ($_ -split "`t", 2)[0] })
    if ($packages -notcontains 'vim' -or $packages -notcontains 'cascadia-code-nerd-font') {
        throw 'package loop did not reach the end'
    }
    Assert-CleanedUp $result
    Write-Host 'PASS success'
}

function Invoke-StopCase {
    $result = Invoke-InstallUnderTest -StopAt 'vim'
    if (-not $result.Failed) { throw 'a stopped install was reported as success' }
    Assert-ObservedUsesProtectedTemp $result
    $packages = @($result.Observed | ForEach-Object { ($_ -split "`t", 2)[0] })
    if ($packages -notcontains 'googlechrome' -or $packages -notcontains 'vim') {
        throw 'stop case did not reach the stopped package'
    }
    if ($packages -contains 'cascadia-code-nerd-font') {
        throw 'packages continued after the pipeline stopped'
    }
    Assert-CleanedUp $result
    Write-Host 'PASS stop'
}

function Invoke-BootstrapCase {
    $result = Invoke-InstallUnderTest -FailBootstrap
    if ($result.Failed) { throw 'a statement-terminating bootstrap error aborted the package loop' }
    Assert-ObservedUsesProtectedTemp $result
    $packages = @($result.Observed | ForEach-Object { ($_ -split "`t", 2)[0] })
    if ($packages -notcontains 'cascadia-code-nerd-font') {
        throw 'bootstrap error skipped the rest of the package loop'
    }
    Assert-CleanedUp $result
    Write-Host 'PASS bootstrap'
}

switch ($Mode) {
    'success' { Invoke-SuccessCase }
    'stop' { Invoke-StopCase }
    'bootstrap' { Invoke-BootstrapCase }
    'all' {
        foreach ($case in @('success', 'stop', 'bootstrap')) {
            & pwsh -NoProfile -File $PSCommandPath -Mode $case
            if ($LASTEXITCODE -ne 0) {
                throw "case $case failed with exit $LASTEXITCODE"
            }
        }
        Write-Host 'All protected-temp cleanup tests passed.'
    }
}
