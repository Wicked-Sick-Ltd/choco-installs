# choco-installs

List of packages to install on a new Windows machine using [Chocolatey](https://chocolatey.org/).

This repository contains a simple, repeatable way to bootstrap a fresh Windows environment with commonly used tools.

## What this repo includes

- A PowerShell-based package list/install script(s)
- A curated set of commonly installed apps and utilities
- Supporting docs for contribution and security reporting

## Prerequisites

- Windows 10/11
- Administrator PowerShell session (recommended)
- Chocolatey installed

If you do not already have Chocolatey installed, follow the official install instructions:

- https://chocolatey.org/install

## Usage

1. Clone this repository:

```powershell
git clone https://github.com/Wicked-Sick-Ltd/choco-installs.git
cd choco-installs
```

2. Open **PowerShell as Administrator** (elevated).

3. Allow script execution for the **current session only**, then run the install script:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\install.ps1
```

> [!WARNING]
> `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass` temporarily lowers protections for this PowerShell session.
> Only run scripts you trust and have reviewed. Do **not** use broader scopes (like `LocalMachine`) unless you understand and accept the security impact.

If script execution is blocked, PowerShell can show an error similar to:

`running scripts is disabled on this system` (`PSSecurityException`).

## Customizing your package set

- Add/remove packages in the script or package list file.
- Keep changes focused and tested on a clean VM when possible.
- Prefer stable packages unless there is a clear need for prerelease/nightly builds.

## Safety notes

- Review package names before running bulk installs.
- Pin versions for mission-critical tools when reproducibility matters.
- Run in an elevated PowerShell when package installs require admin rights.

## Contributing

Contributions are welcome. Please read [CONTRIBUTING.md](CONTRIBUTING.md) first.

## Security

Please report vulnerabilities privately. See [SECURITY.md](SECURITY.md).

## License

This project is licensed under the MIT License - see [LICENSE](LICENSE).
