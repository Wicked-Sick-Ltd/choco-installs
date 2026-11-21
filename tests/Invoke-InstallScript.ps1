# Runs install.ps1 in this process with the two calls that cannot be
# completed on a non-Windows host stubbed, then lets the package loop call
# the real commands. choco is the vim 9.2.1355 installer chain. Registry
# cmdlets update the same AutoRun store that chain reads when vim is reached.
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallScript,

    [Parameter(Mandatory = $true)]
    [string]$RegistryFile,

    [Parameter(Mandatory = $true)]
    [string]$ChainScript,

    [Parameter(Mandatory = $true)]
    [string]$TraceFile,

    [Parameter(Mandatory = $true)]
    [string]$InvocationLog,

    # Define the stubs without running install.ps1. Tests use this to call
    # the registry cmdlets directly.
    [switch]$SkipInstall
)

$ErrorActionPreference = 'Stop'

function Set-ExecutionPolicy {
    # Windows PowerShell accepts the script's process-scope Bypass.
    # This host has no execution-policy store; skipping it lets the
    # remainder of install.ps1 run.
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
        # install.ps1 bootstraps Chocolatey by downloading install.ps1.
        # That bootstrap starts 7za.exe directly and does not launch cmd.exe.
        # Return an empty script so the package loop is what runs next.
        $client = [pscustomobject]@{}
        Add-Member -InputObject $client -MemberType ScriptMethod -Name DownloadString -Value {
            param($Url)
            return ''
        }
        return $client
    }

    $forward = @{}
    if ($PSBoundParameters.ContainsKey('TypeName')) {
        $forward['TypeName'] = $TypeName
    }
    if ($PSBoundParameters.ContainsKey('ArgumentList')) {
        $forward['ArgumentList'] = $ArgumentList
    }
    if ($ComObject) {
        $forward['ComObject'] = $true
    }
    Microsoft.PowerShell.Utility\New-Object @forward
}

function Update-AutoRunStore {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Value,

        [switch]$Clear
    )

    if ($Name -ne 'AutoRun') {
        return
    }
    # Real Remove-ItemProperty and Set-ItemProperty take a path array. One
    # call can name both Command Processor keys; each element is applied on
    # its own so a second path is not dropped.
    foreach ($entry in $Path) {
        if ($entry -notmatch '(?i)^HK(CU|LM):\\Software\\Microsoft\\Command Processor\\?$') {
            continue
        }
        $hive = if ($entry -match '(?i)^HKCU:') { 'HKCU' } else { 'HKLM' }
        & python3 -c @'
import json, sys
path, hive, mode, value = sys.argv[1:]
state = json.load(open(path))
state[hive] = None if mode == "clear" else value
json.dump(state, open(path, "w"))
'@ $RegistryFile $hive $(if ($Clear) { 'clear' } else { 'set' }) $(if ($null -eq $Value) { '' } else { $Value })
    }
}

function Remove-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    Update-AutoRunStore -Path $Path -Name $Name -Clear
}

function Set-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [string[]]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ([string]::IsNullOrEmpty($text)) {
        Update-AutoRunStore -Path $Path -Name $Name -Clear
    }
    else {
        Update-AutoRunStore -Path $Path -Name $Name -Value $text
    }
}

function choco {
    $package = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ([string]$args[$i] -eq '-y' -and ($i + 1) -lt $args.Count) {
            $package = [string]$args[$i + 1]
        }
    }
    Add-Content -LiteralPath $InvocationLog -Value ("install {0}" -f $package)
    if ($package -eq 'vim') {
        & python3 $ChainScript --registry $RegistryFile --trace $TraceFile
        if ($LASTEXITCODE -ne 0) {
            throw "vim install chain exited $LASTEXITCODE"
        }
    }
    $global:LASTEXITCODE = 0
}

if (-not $SkipInstall) {
    . $InstallScript
}
