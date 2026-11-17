#!/usr/bin/env bash
# Linux bootstrap for Cursor Cloud Agents.
# Installs PowerShell 7, PSScriptAnalyzer, and Pester so agents can parse-check
# and lint this repo. Does not run install.ps1: Chocolatey cannot run here.
# No CI workflow pins module versions, so this installs current
# PSScriptAnalyzer and Pester 5 or newer.

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

warn() {
  printf 'WARNING: %s\n' "$*"
}

apt_get() {
  sudo -n env DEBIAN_FRONTEND=noninteractive apt-get \
    -o Dpkg::Options::=--force-confdef \
    -o Dpkg::Options::=--force-confold \
    "$@"
}

install_pwsh() {
  if command -v pwsh >/dev/null 2>&1; then
    echo "pwsh already installed: $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
    return 0
  fi

  apt_get update
  apt_get install -y wget apt-transport-https software-properties-common

  # shellcheck disable=SC1091
  . /etc/os-release
  if [[ -z "${VERSION_ID:-}" ]]; then
    echo "Ubuntu VERSION_ID is unset; cannot register the Microsoft package repository." >&2
    return 1
  fi

  local deb url
  url="https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb"
  deb="$(mktemp /tmp/packages-microsoft-prod.XXXXXX.deb)"
  if ! wget -q -O "$deb" "$url"; then
    rm -f "$deb"
    echo "Failed to download the Microsoft package repository config." >&2
    return 1
  fi
  sudo -n dpkg -i "$deb"
  rm -f "$deb"

  apt_get update
  apt_get install -y powershell
  hash -r
  command -v pwsh >/dev/null 2>&1
}

install_modules() {
  # pwsh -Command - does not reliably run a multi-statement script on stdin.
  # Write a temp file and execute that. It is not install.ps1.
  local script
  script="$(mktemp /tmp/choco-installs-modules.XXXXXX.ps1)"
  # shellcheck disable=SC2064
  trap "rm -f '$script'; trap - RETURN" RETURN
  cat > "$script" <<'PS'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$ConfirmPreference = 'None'

function Get-RequiredModule {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [version]$MinimumVersion
    )

    return Get-Module -ListAvailable -Name $Name |
        Where-Object { -not $MinimumVersion -or $_.Version -ge $MinimumVersion } |
        Sort-Object Version -Descending |
        Select-Object -First 1
}

$nuget = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
    Where-Object { $_.Version -ge [version]'2.8.5.201' } |
    Select-Object -First 1
if (-not $nuget) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope AllUsers | Out-Null
}

Import-PackageProvider -Name NuGet -Force | Out-Null
$gallery = Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue
if (-not $gallery) {
    Register-PSRepository -Name PSGallery -SourceLocation 'https://www.powershellgallery.com/api/v2' -InstallationPolicy Trusted
}
else {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

$required = @(
    @{ Name = 'PSScriptAnalyzer' }
    @{ Name = 'Pester'; MinimumVersion = [version]'5.0.0' }
)

foreach ($mod in $required) {
    $have = Get-RequiredModule @mod
    if ($have) {
        Write-Output ("Module present: {0} {1}" -f $mod.Name, $have.Version)
        continue
    }

    $installParams = @{
        Name          = $mod.Name
        Scope         = 'AllUsers'
        Force         = $true
        AllowClobber  = $true
        AcceptLicense = $true
        Confirm       = $false
    }
    if ($mod.ContainsKey('MinimumVersion')) {
        $installParams.MinimumVersion = $mod.MinimumVersion
    }

    $installed = $null
    $attempt = 0
    do {
        $attempt++
        try {
            Install-Module @installParams
            $installed = @(Get-Module -ListAvailable -Refresh -Name $mod.Name |
                Where-Object { -not $mod.MinimumVersion -or $_.Version -ge $mod.MinimumVersion } |
                Sort-Object Version -Descending)
            if ($installed.Count -gt 0) {
                $installed = $installed[0]
            }
            else {
                $installed = $null
                throw "No installed module named $($mod.Name) was found after Install-Module."
            }
        }
        catch {
            if ($attempt -ge 3) { throw }
            Write-Output ("Retrying {0} ({1}/3) after: {2}" -f $mod.Name, ($attempt + 1), $_.Exception.Message)
            Start-Sleep -Seconds (2 * $attempt)
            Import-PackageProvider -Name NuGet -Force | Out-Null
        }
    } while (-not $installed -and $attempt -lt 3)
    Write-Output ("Module installed: {0} {1}" -f $mod.Name, $installed.Version)
}
PS
  sudo -n pwsh -NoProfile -NonInteractive -File "$script"
}

verify_modules_visible() {
  # Confirm the agent user can see modules installed for all users.
  pwsh -NoProfile -NonInteractive -Command '$ErrorActionPreference = "Stop"; $analyzer = @(Get-Module -ListAvailable -Name PSScriptAnalyzer); $pester = @(Get-Module -ListAvailable -Name Pester | Where-Object { $_.Version -ge [version]"5.0.0" }); if ($analyzer.Count -lt 1) { throw "PSScriptAnalyzer is not visible to the current user" }; if ($pester.Count -lt 1) { throw "Pester 5 or newer is not visible to the current user" }; "Visible to current user: PSScriptAnalyzer $($analyzer[0].Version); Pester $($pester[0].Version)"'
}

install_pwsh
install_modules
verify_modules_visible

# Optional on Linux. Missing choco must not fail this install.
if ! command -v choco >/dev/null 2>&1; then
  warn "optional tool 'choco' is not available. Chocolatey cannot run on this Linux VM, so install.ps1 was not executed."
fi

# Names only. This repository does not require any of them for lint or parse checks.
optional_env_vars=()
if ((${#optional_env_vars[@]} > 0)); then
  for name in "${optional_env_vars[@]}"; do
    if [[ -z "${!name:-}" ]]; then
      warn "optional env var '${name}' is not set."
    fi
  done
fi

echo "Cloud agent install complete. pwsh $(pwsh -NoProfile -Command '$PSVersionTable.PSVersion.ToString()')"
