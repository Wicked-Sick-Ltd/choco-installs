# Dot-sources install.ps1 with the registry cmdlets and choco stubbed so the
# AutoRun save/restore and the stop/finally path can run on a non-Windows host.
param(
    [Parameter(Mandatory = $true)]
    [string]$InstallScript,

    [Parameter(Mandatory = $true)]
    [string]$RegistryFile,

    [Parameter(Mandatory = $true)]
    [string]$InvocationLog
)

$ErrorActionPreference = 'Continue'

function Read-Store {
    $raw = [System.IO.File]::ReadAllText($RegistryFile)
    return $raw | ConvertFrom-Json -AsHashtable
}

function Write-Store {
    param($Store)
    $json = $Store | ConvertTo-Json -Depth 6
    [System.IO.File]::WriteAllText($RegistryFile, $json)
}

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

function Get-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($Name -ne 'AutoRun') {
        return
    }
    $store = Read-Store
    if (-not $store.ContainsKey($Path)) {
        return
    }
    $entry = $store[$Path]
    if ($null -eq $entry) {
        return
    }
    [pscustomobject]@{ AutoRun = $entry['value'] }
}

function Get-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('LiteralPath')]
        [string]$Path
    )

    if ($Path -notlike 'HK*:*') {
        return Microsoft.PowerShell.Management\Get-Item -LiteralPath $Path
    }
    $store = Read-Store
    if (-not $store.ContainsKey($Path) -or $null -eq $store[$Path]) {
        return
    }
    $obj = [pscustomobject]@{ EntryPath = $Path }
    Add-Member -InputObject $obj -MemberType ScriptMethod -Name GetValueKind -Value {
        param($Name)
        $current = Read-Store
        return [Microsoft.Win32.RegistryValueKind]$current[$this.EntryPath]['kind']
    }
    Add-Member -InputObject $obj -MemberType ScriptMethod -Name GetValue -Value {
        param($Name, $Default, $Options)
        $current = Read-Store
        return $current[$this.EntryPath]['value']
    }
    Add-Member -InputObject $obj -MemberType ScriptMethod -Name Close -Value { }
    return $obj
}

function Test-Path {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [Alias('LiteralPath')]
        [string]$Path
    )

    if ($Path -like 'HK*:*') {
        $store = Read-Store
        return $store.ContainsKey($Path)
    }
    Microsoft.PowerShell.Management\Test-Path -LiteralPath $Path
}

function New-Item {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Path,

        [string]$ItemType,
        [switch]$Force
    )

    if ($Path -like 'HK*:*') {
        $store = Read-Store
        if (-not $store.ContainsKey($Path)) {
            $store[$Path] = $null
            Write-Store $store
        }
        return
    }
    $forward = @{ Path = $Path; Force = [bool]$Force }
    if (-not [string]::IsNullOrWhiteSpace($ItemType)) {
        $forward['ItemType'] = $ItemType
    }
    Microsoft.PowerShell.Management\New-Item @forward | Out-Null
}

function Remove-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($env:CHOCO_TEST_ABORT_REMOVE -eq '1' -and $Path -like '*WOW6432Node*') {
        throw 'simulated failure removing AutoRun'
    }
    if ($Name -ne 'AutoRun') {
        return
    }
    $store = Read-Store
    if (-not $store.ContainsKey($Path)) {
        return
    }
    $store[$Path] = $null
    Write-Store $store
}

function New-ItemProperty {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [object]$Value,

        [string]$PropertyType,
        [switch]$Force
    )

    if ($Name -ne 'AutoRun') {
        return
    }
    $store = Read-Store
    $store[$Path] = @{ kind = [string]$PropertyType; value = $Value }
    Write-Store $store
}

function choco {
    $package = $null
    for ($i = 0; $i -lt $args.Count; $i++) {
        if ([string]$args[$i] -eq '-y' -and ($i + 1) -lt $args.Count) {
            $package = [string]$args[$i + 1]
        }
    }
    $store = Read-Store
    $present = 0
    foreach ($key in @($store.Keys)) {
        if ($null -ne $store[$key]) {
            $present++
        }
    }
    Add-Content -LiteralPath $InvocationLog -Value ("install {0} present={1}" -f $package, $present)
    if ($env:CHOCO_TEST_STOP_AT -eq $package) {
        throw (New-Object System.Management.Automation.PipelineStoppedException)
    }
    $global:LASTEXITCODE = 0
}

. $InstallScript
