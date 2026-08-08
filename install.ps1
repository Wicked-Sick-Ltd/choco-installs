# =========================================================
# Chocolatey bootstrap for a new Windows machine
# =========================================================

# 1. Install Chocolatey (run in an elevated PowerShell)
Set-ExecutionPolicy Bypass -Scope Process -Force; [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072; iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))

# 2. Open a NEW shell (so choco is on PATH), then install packages below.
#    Tip: you can install everything in one go with:
#    choco install -y googlechrome rclone vim rsync gh git 7zip ...
#    The -y flag skips confirmation prompts, useful for a full bootstrap run.

# -----------------------------------------------------------
# My seed list
# -----------------------------------------------------------
choco install -y googlechrome
choco install -y rclone
choco install -y vim
choco install -y rsync
choco install -y gh
choco install -y git

# -----------------------------------------------------------
# Core CLI / shell essentials (pairs naturally with git/gh/vim)
# -----------------------------------------------------------
choco install -y 7zip                 # archive tool, used everywhere
choco install -y curl                 # Windows ships one, but choco's is often newer
choco install -y wget
choco install -y jq                   # JSON processor, invaluable with gh/curl
choco install -y sudo                 # gsudo-style elevation from any shell
choco install -y grep
choco install -y sed
choco install -y less

# -----------------------------------------------------------
# Terminal / shell environment
# -----------------------------------------------------------
choco install -y microsoft-windows-terminal
choco install -y powershell-core      # pwsh (v7+), alongside Windows PowerShell
choco install -y starship             # cross-shell prompt, works well with git

# -----------------------------------------------------------
# Editors / IDEs
# -----------------------------------------------------------
choco install -y vscode
choco install -y notepadplusplus

# -----------------------------------------------------------
# Dev runtimes & package managers
# (skip any you don't personally use)
# -----------------------------------------------------------
choco install -y nodejs-lts
choco install -y python
choco install -y openjdk
choco install -y golang
choco install -y rust

# -----------------------------------------------------------
# Containers / virtualization
# -----------------------------------------------------------
choco install -y docker-desktop

# -----------------------------------------------------------
# Cloud & infra CLIs
# -----------------------------------------------------------
choco install -y awscli
choco install -y azure-cli
choco install -y terraform
choco install -y kubernetes-cli       # kubectl

# -----------------------------------------------------------
# Networking / remote access
# -----------------------------------------------------------
choco install -y putty                # ssh/telnet client + puttygen
choco install -y winscp               # GUI sftp/scp, complements rsync
choco install -y openssh              # ssh/scp/sftp client+server if not already present
choco install -y mobaxterm             # alternative all-in-one terminal + X server

# -----------------------------------------------------------
# API / DB tooling
# -----------------------------------------------------------
choco install -y postman
choco install -y dbeaver              # universal DB GUI client

# -----------------------------------------------------------
# System utilities (Sysinternals-adjacent, general QoL)
# -----------------------------------------------------------
choco install -y powertoys            # not enough people know about this.  It's the best thing on windows no-one knows about! Window snapping, FancyZones, PowerToys Run, etc.
choco install -y sysinternals          # full Sysinternals suite - these are still going strong after all these years
choco install -y everything            # instant file search
choco install -y treesizefree          # disk usage visualizer

# -----------------------------------------------------------
# Browsers (beyond Chrome, useful for cross-browser testing)
# -----------------------------------------------------------
choco install -y firefox
choco install -y microsoft-edge

# -----------------------------------------------------------
# Media / misc
# -----------------------------------------------------------
choco install -y vlc
choco install -y ffmpeg 
choco install -y greenshot             # lightweight screenshot tool

# -----------------------------------------------------------
# Fonts (nice with Windows Terminal / vim / vscode)
# -----------------------------------------------------------
choco install -y cascadia-code-nerd-font
