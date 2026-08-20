# Deploys the tray tool files into a GitHub Actions runner directory.
#
# Usage:
#   .\install.ps1                      # install to C:\actions-runner
#   .\install.ps1 -RunnerDir D:\runner -SkipBackup
#
# Existing copies are backed up as <file>.bak unless -SkipBackup is used.

[CmdletBinding()]
param(
    [string]$RunnerDir = 'C:\actions-runner',
    [switch]$SkipBackup
)

$ErrorActionPreference = 'Stop'

$SourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path

function Write-Step {
    param([string]$Message)
    Write-Host "[install] $Message" -ForegroundColor Cyan
}

if (-not (Test-Path -LiteralPath $RunnerDir)) {
    Write-Error "Runner directory not found: $RunnerDir"
    exit 1
}

if (-not (Test-Path -LiteralPath (Join-Path $RunnerDir 'bin\Runner.Listener.exe'))) {
    Write-Host "[install] WARNING: no bin\Runner.Listener.exe found under $RunnerDir - verify this is the runner directory." -ForegroundColor Yellow
}

$files = @('runner-tray.ps1', 'runner-tray.cmd', 'README.md', 'LICENSE')
foreach ($file in $files) {
    $src = Join-Path $SourceRoot $file
    $dst = Join-Path $RunnerDir $file
    if (-not (Test-Path -LiteralPath $src)) {
        continue
    }

    if ((Test-Path -LiteralPath $dst) -and (-not $SkipBackup)) {
        $backup = "$dst.bak"
        Copy-Item -LiteralPath $dst -Destination $backup -Force
        Write-Step "Backed up existing $file to $backup"
    }

    Copy-Item -LiteralPath $src -Destination $dst -Force
    Write-Step "Installed $file -> $dst"
}

Write-Host ''
Write-Step 'Installation complete.'
Write-Host 'Start the tray by double-clicking runner-tray.cmd, or run:'
Write-Host ("  powershell -NoProfile -ExecutionPolicy Bypass -Sta -File `"{0}`"" -f (Join-Path $RunnerDir 'runner-tray.ps1'))
