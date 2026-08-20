[CmdletBinding()]
param(
    [switch]$RunnerHost,
    [switch]$Status,
    [switch]$StartRunner,
    [switch]$StopRunner,
    [switch]$LogPath,
    [switch]$SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptPath = $PSCommandPath
if (-not $ScriptPath) {
    $ScriptPath = $MyInvocation.MyCommand.Path
}

$ScriptRoot = Split-Path -Parent $ScriptPath
$BinRoot = Join-Path $ScriptRoot 'bin'
$ListenerExe = Join-Path $BinRoot 'Runner.Listener.exe'
$WorkerExe = Join-Path $BinRoot 'Runner.Worker.exe'
$RunCmdPath = Join-Path $ScriptRoot 'run.cmd'
$DiagRoot = Join-Path $ScriptRoot '_diag'
$StateRoot = Join-Path $ScriptRoot '.trayicon'
$HostPidFile = Join-Path $StateRoot 'runner-host.pid'
$StopFlagFile = Join-Path $StateRoot 'runner-host.stop'
$HostLogFile = Join-Path $StateRoot 'runner-host.log'
$RunCmdLiveLogFile = Join-Path $StateRoot 'run-cmd-live.log'
$UpdateFinishedFile = Join-Path $ScriptRoot 'update.finished'
$ReadmePath = Join-Path $ScriptRoot 'README.md'
$AutostartRegPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
# Prefer Windows PowerShell (guaranteed on Windows, supports -Sta); fall back
# to pwsh when the host only ships PowerShell 7.
$WindowsPowerShellExe = Join-Path $PSHOME 'powershell.exe'
if (Test-Path -LiteralPath $WindowsPowerShellExe) {
    $PowerShellExe = $WindowsPowerShellExe
} else {
    $pwshCommand = Get-Command 'pwsh' -ErrorAction SilentlyContinue
    if ($pwshCommand) {
        $PowerShellExe = $pwshCommand.Source
    } else {
        $PowerShellExe = $WindowsPowerShellExe
    }
}
$sha1 = [System.Security.Cryptography.SHA1]::Create()
try {
    $pathHashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ScriptRoot.ToLowerInvariant()))
} finally {
    $sha1.Dispose()
}
$PathHash = ([System.BitConverter]::ToString($pathHashBytes)).Replace('-', '')
$TrayAppMutexName = "Global\GitHubRunnerTrayApp_$PathHash"
$RunnerHostMutexName = "Global\GitHubRunnerHost_$PathHash"
# Per-directory autostart value so multiple runner directories do not
# overwrite each other's startup entry.
$AutostartValueName = "GitHubRunnerTrayIcon_$PathHash"
$LegacyAutostartValueName = 'GitHubRunnerTrayIcon'
$script:UnresolvedRunnerProcesses = @()

function Ensure-StateDirectory {
    if (-not (Test-Path -LiteralPath $StateRoot)) {
        [void](New-Item -Path $StateRoot -ItemType Directory -Force)
    }
}

function Enter-SingleInstance {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $mutex = New-Object System.Threading.Mutex($false, $Name)
    $hasHandle = $false
    try {
        $hasHandle = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $hasHandle = $true
    }

    if (-not $hasHandle) {
        $mutex.Dispose()
        return $null
    }

    return $mutex
}

function Exit-SingleInstance {
    param(
        [System.Threading.Mutex]$Mutex
    )

    if (-not $Mutex) {
        return
    }

    try {
        $Mutex.ReleaseMutex()
    } catch {
    }

    $Mutex.Dispose()
}

function Test-LogRollover {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$MaxBytes = 5242880
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    try {
        $item = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($item.Length -gt $MaxBytes) {
            $rotatedPath = "$Path.1"
            Remove-Item -LiteralPath $rotatedPath -Force -ErrorAction SilentlyContinue
            Rename-Item -LiteralPath $Path -NewName (Split-Path -Leaf $rotatedPath) -ErrorAction Stop
        }
    } catch {
        # Rotation is best-effort; never break logging over it.
    }
}

function Write-HostLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Ensure-StateDirectory
    Test-LogRollover -Path $HostLogFile
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $HostLogFile -Value "$timestamp $Message"
}

function Get-LastHostLogLine {
    if (-not (Test-Path -LiteralPath $HostLogFile)) {
        return $null
    }

    $line = Get-Content -LiteralPath $HostLogFile -Tail 1 -ErrorAction SilentlyContinue
    if ($line -is [string]) {
        return $line
    }

    if ($line) {
        return ($line | Select-Object -Last 1)
    }

    return $null
}

function Get-RunnerProcesses {
    $all = @(Get-Process -Name 'Runner.Listener', 'Runner.Worker' -ErrorAction SilentlyContinue)
    if ($all.Count -eq 0) {
        $script:UnresolvedRunnerProcesses = @()
        return @()
    }

    $matched = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
    $unresolved = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
    foreach ($process in $all) {
        $expectedPath = $null
        if ($process.ProcessName -eq 'Runner.Listener') {
            $expectedPath = $ListenerExe
        } elseif ($process.ProcessName -eq 'Runner.Worker') {
            $expectedPath = $WorkerExe
        }

        if (-not $expectedPath) {
            continue
        }

        $exePath = $null
        try {
            $exePath = $process.Path
        } catch {
            $exePath = $null
        }

        if (-not $exePath) {
            # Process.Path is not readable (e.g. the process runs under another
            # account). Try CIM as a fallback; it can still return $null without
            # elevation.
            try {
                $cimProcess = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $process.Id) -ErrorAction Stop
                $exePath = $cimProcess.ExecutablePath
            } catch {
                $exePath = $null
            }
        }

        if ($exePath -and ($exePath -ieq $expectedPath)) {
            [void]$matched.Add($process)
            continue
        }

        if (-not $exePath) {
            # Same-named process whose directory we cannot verify; report it so
            # the state can surface as 'Unknown' instead of a false 'Stopped'.
            [void]$unresolved.Add($process)
        }
    }

    $script:UnresolvedRunnerProcesses = $unresolved.ToArray()
    return $matched.ToArray()
}

function Get-RunnerState {
    $processes = Get-RunnerProcesses
    if ($processes | Where-Object { $_.ProcessName -eq 'Runner.Worker' }) {
        return 'Busy'
    }

    if ($processes | Where-Object { $_.ProcessName -eq 'Runner.Listener' }) {
        return 'Idle'
    }

    if (@($script:UnresolvedRunnerProcesses).Count -gt 0) {
        return 'Unknown'
    }

    return 'Stopped'
}

function Remove-IfExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
    }
}

function Get-RunnerHostPid {
    if (-not (Test-Path -LiteralPath $HostPidFile)) {
        return $null
    }

    $rawPid = (Get-Content -LiteralPath $HostPidFile -ErrorAction Stop | Select-Object -First 1).Trim()
    if (-not $rawPid) {
        Remove-IfExists -Path $HostPidFile
        return $null
    }

    $pidValue = 0
    if (-not [int]::TryParse($rawPid, [ref]$pidValue)) {
        Remove-IfExists -Path $HostPidFile
        return $null
    }

    $process = Get-Process -Id $pidValue -ErrorAction SilentlyContinue
    if (-not $process) {
        Remove-IfExists -Path $HostPidFile
        return $null
    }

    # The PID file must point at our PowerShell host process, not at some
    # unrelated process that happened to reuse the PID.
    if ($process.ProcessName -notin @('powershell', 'pwsh')) {
        Remove-IfExists -Path $HostPidFile
        Write-HostLog -Message ("Stale host PID file: PID {0} belongs to {1}, not a PowerShell host process." -f $pidValue, $process.ProcessName)
        return $null
    }

    # Best-effort command-line check; skip when it is not readable (elevation).
    try {
        $cimProcess = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f $pidValue) -ErrorAction Stop
        if ($cimProcess -and $cimProcess.CommandLine -and ($cimProcess.CommandLine -notmatch '-RunnerHost')) {
            Remove-IfExists -Path $HostPidFile
            Write-HostLog -Message ("Stale host PID file: PID {0} command line does not reference -RunnerHost." -f $pidValue)
            return $null
        }
    } catch {
        # Cannot verify the command line; accept the PID as-is.
    }

    return $pidValue
}

function Get-AutostartCommand {
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{1}"' -f $PowerShellExe, $ScriptPath)
}

function Test-AutostartEnabled {
    try {
        $currentValue = (Get-ItemProperty -Path $AutostartRegPath -Name $AutostartValueName -ErrorAction Stop).$AutostartValueName
        if ([string]::IsNullOrWhiteSpace($currentValue)) {
            return $false
        }

        # Only report enabled when the stored command still points at this
        # exact script; a stale entry (directory moved, old value name) is not
        # actually functional even though the value exists.
        return ($currentValue.Trim() -ieq (Get-AutostartCommand))
    } catch {
        return $false
    }
}

function Set-AutostartEnabled {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Enabled
    )

    if ($Enabled) {
        [void](New-ItemProperty -Path $AutostartRegPath -Name $AutostartValueName -PropertyType String -Value (Get-AutostartCommand) -Force)
        return
    }

    Remove-ItemProperty -Path $AutostartRegPath -Name $AutostartValueName -ErrorAction SilentlyContinue
    # Clean up the fixed name used before per-directory hashing existed.
    Remove-ItemProperty -Path $AutostartRegPath -Name $LegacyAutostartValueName -ErrorAction SilentlyContinue
}

function Write-StopSignal {
    Ensure-StateDirectory
    Set-Content -Path $StopFlagFile -Value (Get-Date -Format o)
}

function Clear-StopSignal {
    Remove-IfExists -Path $StopFlagFile
}

function Wait-ForState {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ExpectedState,
        [int]$TimeoutSeconds = 15
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if ((Get-RunnerState) -eq $ExpectedState) {
            return $true
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    return ((Get-RunnerState) -eq $ExpectedState)
}

function Start-RunnerControl {
    param(
        [int]$IdleTimeoutSeconds = 30
    )

    $state = Get-RunnerState
    if ($state -eq 'Unknown') {
        return 'Runner state is unknown: a Runner.Listener/Runner.Worker process exists whose directory cannot be verified (it likely runs under another account). Run the tray elevated or stop that runner before starting this one.'
    }

    if ($state -ne 'Stopped') {
        return "Runner is already $state."
    }

    $hostPid = Get-RunnerHostPid
    if ($hostPid) {
        return "Runner host is already running (PID: $hostPid)."
    }

    Ensure-StateDirectory
    Clear-StopSignal

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-File', ('"{0}"' -f $ScriptPath),
        '-RunnerHost'
    )

    [void](Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $ScriptRoot)

    # Wait for the listener, but fail fast once the host has appeared and then
    # disappeared (e.g. run.cmd missing) instead of waiting out the full timer.
    $sawHostPid = $false
    $deadline = (Get-Date).AddSeconds($IdleTimeoutSeconds)
    do {
        if ((Get-RunnerState) -eq 'Idle') {
            return 'Runner started.'
        }

        $hostPid = Get-RunnerHostPid
        if ($hostPid) {
            $sawHostPid = $true
        } elseif ($sawHostPid) {
            break
        }

        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $deadline)

    $lastLine = Get-LastHostLogLine
    if ($lastLine) {
        return "Runner start failed. Last host log: $lastLine"
    }

    return "Runner start failed: no idle listener was detected within $IdleTimeoutSeconds seconds."
}

function Stop-RunnerProcesses {
    $processes = @(Get-RunnerProcesses | Sort-Object -Property @{ Expression = { if ($_.ProcessName -eq 'Runner.Worker') { 0 } else { 1 } } })
    if ($processes.Count -eq 0) {
        return
    }

    foreach ($process in $processes) {
        try {
            Stop-Process -Id $process.Id -Force
        } catch {
            Write-HostLog -Message ("Failed to stop process {0} ({1}): {2}" -f $process.ProcessName, $process.Id, $_.Exception.Message)
        }
    }
}

function Stop-RunnerControl {
    if ((Get-RunnerState) -eq 'Unknown') {
        return 'Runner state is unknown: a same-named runner process exists whose directory cannot be verified. Stop aborted to avoid killing a runner outside this directory.'
    }

    Write-StopSignal

    $hostPid = Get-RunnerHostPid
    if ($hostPid) {
        $deadline = (Get-Date).AddSeconds(20)
        do {
            if ((Get-RunnerState) -eq 'Stopped') {
                break
            }
            Start-Sleep -Milliseconds 500
        } while ((Get-Date) -lt $deadline)
    }

    if ((Get-RunnerState) -ne 'Stopped') {
        Stop-RunnerProcesses
    }

    if ($hostPid) {
        $hostProcess = Get-Process -Id $hostPid -ErrorAction SilentlyContinue
        if ($hostProcess) {
            Stop-Process -Id $hostPid -Force
        }
    }

    Remove-IfExists -Path $HostPidFile
    Clear-StopSignal
    return 'Runner stopped.'
}

function Invoke-RunnerHost {
    Ensure-StateDirectory
    $hostMutex = Enter-SingleInstance -Name $RunnerHostMutexName
    if (-not $hostMutex) {
        Write-HostLog -Message 'Runner host instance already exists. Duplicate host will exit.'
        return
    }

    Set-Content -Path $HostPidFile -Value $PID
    Clear-StopSignal
    Write-HostLog -Message 'Runner host started.'

    try {
        while ($true) {
            if (Test-Path -LiteralPath $StopFlagFile) {
                Write-HostLog -Message 'Stop signal detected before launch.'
                break
            }

            if (-not (Test-Path -LiteralPath $RunCmdPath)) {
                Write-HostLog -Message ("run.cmd not found: {0}" -f $RunCmdPath)
                break
            }

            Test-LogRollover -Path $RunCmdLiveLogFile
            Add-Content -Path $RunCmdLiveLogFile -Value ("[{0}] Starting run.cmd" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            # Launch via cmd.exe so run.cmd output is APPENDED to the live log
            # (Start-Process -RedirectStandardOutput truncates the file) and so
            # stderr is merged into the same live log (2>&1).
            $redirectCommand = '""{0}" >> "{1}" 2>&1"' -f $RunCmdPath, $RunCmdLiveLogFile
            $runCmdProcess = Start-Process -FilePath $env:ComSpec -ArgumentList '/c', $redirectCommand -WindowStyle Hidden -WorkingDirectory $ScriptRoot -PassThru
            Write-HostLog -Message ("run.cmd started with PID {0}." -f $runCmdProcess.Id)

            while (-not $runCmdProcess.HasExited) {
                if (Test-Path -LiteralPath $StopFlagFile) {
                    Write-HostLog -Message ("Stop signal detected; terminating run.cmd PID {0}." -f $runCmdProcess.Id)
                    Stop-RunnerProcesses
                    Stop-Process -Id $runCmdProcess.Id -Force -ErrorAction SilentlyContinue
                    if (-not $runCmdProcess.WaitForExit(15000)) {
                        # Never block forever: retry once, then give up on the wait.
                        Write-HostLog -Message ("run.cmd PID {0} still alive after 15 s; forcing termination again." -f $runCmdProcess.Id)
                        Stop-Process -Id $runCmdProcess.Id -Force -ErrorAction SilentlyContinue
                        [void]$runCmdProcess.WaitForExit(10000)
                    }
                    break
                }

                Start-Sleep -Seconds 1
            }

            $exitCode = if ($runCmdProcess.HasExited) { $runCmdProcess.ExitCode } else { -1 }
            Write-HostLog -Message ("run.cmd exited with code {0}." -f $exitCode)
            Add-Content -Path $RunCmdLiveLogFile -Value ("[{0}] run.cmd exited with code {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $exitCode)

            if (Test-Path -LiteralPath $StopFlagFile) {
                break
            }

            if ($exitCode -eq 0) {
                break
            }

            Write-HostLog -Message 'run.cmd exited unexpectedly; restarting in 5 seconds.'
            Start-Sleep -Seconds 5
        }
    } finally {
        Write-HostLog -Message 'Runner host stopping.'
        Remove-IfExists -Path $HostPidFile
        Clear-StopSignal
        Exit-SingleInstance -Mutex $hostMutex
    }
}

function Wait-PathExists {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutSeconds = 30
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        if (Test-Path -LiteralPath $Path) {
            return $true
        }

        Start-Sleep -Seconds 1
    } while ((Get-Date) -lt $deadline)

    return (Test-Path -LiteralPath $Path)
}

function Get-RunnerDiagLogFiles {
    if (-not (Test-Path -LiteralPath $DiagRoot)) {
        return @()
    }

    return @(Get-ChildItem -LiteralPath $DiagRoot -Filter 'Runner_*.log' -File -ErrorAction SilentlyContinue | Sort-Object -Property LastWriteTime -Descending)
}

function Get-LatestRunnerDiagLogPath {
    $latest = Get-RunnerDiagLogFiles | Select-Object -First 1
    if (-not $latest) {
        return $null
    }

    return $latest.FullName
}

function Get-RunCmdLiveLogPath {
    if (-not (Test-Path -LiteralPath $RunCmdLiveLogFile)) {
        return $null
    }

    return $RunCmdLiveLogFile
}

function Get-LogTailText {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$LineCount = 300
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    $content = Get-Content -LiteralPath $Path -Tail $LineCount
    if ($null -eq $content) {
        return ''
    }

    if ($content -is [string]) {
        return $content
    }

    return ($content -join [Environment]::NewLine)
}

function Open-LogFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        [System.Windows.Forms.MessageBox]::Show("Log file not found:`r`n$Path", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
        return
    }

    [void](Start-Process -FilePath $Path)
}

function Show-LogViewerWindow {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$PathResolver,
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $form = New-Object System.Windows.Forms.Form
    $form.Text = $Title
    $form.Width = 960
    $form.Height = 680
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen

    $pathLabel = New-Object System.Windows.Forms.Label
    $pathLabel.Dock = [System.Windows.Forms.DockStyle]::Top
    $pathLabel.AutoSize = $false
    $pathLabel.Height = 40
    $pathLabel.Padding = New-Object System.Windows.Forms.Padding 8, 8, 8, 0

    $textBox = New-Object System.Windows.Forms.TextBox
    $textBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $textBox.Multiline = $true
    $textBox.ReadOnly = $true
    $textBox.ScrollBars = [System.Windows.Forms.ScrollBars]::Both
    $textBox.WordWrap = $false
    $textBox.Font = New-Object System.Drawing.Font('Consolas', 10)

    $buttonPanel = New-Object System.Windows.Forms.FlowLayoutPanel
    $buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $buttonPanel.Height = 38
    $buttonPanel.Padding = New-Object System.Windows.Forms.Padding 8, 4, 8, 4
    $buttonPanel.FlowDirection = [System.Windows.Forms.FlowDirection]::RightToLeft

    $closeButton = New-Object System.Windows.Forms.Button
    $closeButton.Text = 'Close'
    $closeButton.Width = 90
    $closeButton.Add_Click({ $form.Close() })

    $openButton = New-Object System.Windows.Forms.Button
    $openButton.Text = 'Open File'
    $openButton.Width = 90

    $refreshButton = New-Object System.Windows.Forms.Button
    $refreshButton.Text = 'Refresh'
    $refreshButton.Width = 90

    [void]$buttonPanel.Controls.Add($closeButton)
    [void]$buttonPanel.Controls.Add($openButton)
    [void]$buttonPanel.Controls.Add($refreshButton)

    [void]$form.Controls.Add($textBox)
    [void]$form.Controls.Add($pathLabel)
    [void]$form.Controls.Add($buttonPanel)

    $currentPath = $null
    $refreshAction = {
        $resolvedPath = & $PathResolver
        if (-not $resolvedPath) {
            $currentPath = $null
            $pathLabel.Text = 'No runner log found yet.'
            $textBox.Text = ''
            return
        }

        $currentPath = $resolvedPath
        $pathLabel.Text = "Current file: $currentPath"
        $tailText = Get-LogTailText -Path $currentPath -LineCount 300
        if ($null -eq $tailText) {
            $textBox.Text = ''
            return
        }

        if ($textBox.Text -ne $tailText) {
            $textBox.Text = $tailText
            $textBox.SelectionStart = $textBox.TextLength
            $textBox.ScrollToCaret()
        }
    }

    $refreshButton.Add_Click($refreshAction)

    $openButton.Add_Click({
        if ($currentPath) {
            Open-LogFile -Path $currentPath
            return
        }

        [System.Windows.Forms.MessageBox]::Show('No log file available to open.', 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    })

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 3000
    $timer.Add_Tick($refreshAction)
    $timer.Start()

    $form.Add_FormClosed({
        $timer.Stop()
        $timer.Dispose()
        $textBox.Dispose()
        $pathLabel.Dispose()
        $openButton.Dispose()
        $refreshButton.Dispose()
        $closeButton.Dispose()
        $buttonPanel.Dispose()
        $form.Dispose()
    })

    & $refreshAction
    [void]$form.ShowDialog()
}

function Show-TrayError {
    param(
        [Parameter(Mandatory = $true)]
        [System.Management.Automation.ErrorRecord]$ErrorRecord
    )

    try {
        Write-HostLog -Message ("Tray error: {0}" -f $ErrorRecord.Exception.ToString())
    } catch {
    }

    try {
        [System.Windows.Forms.MessageBox]::Show("An error occurred:`r`n$($ErrorRecord.Exception.Message)", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
    }
}

function Ensure-StaForTray {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -eq [System.Threading.ApartmentState]::STA) {
        return $true
    }

    $arguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-WindowStyle', 'Hidden',
        '-Sta',
        '-File', ('"{0}"' -f $ScriptPath)
    )

    [void](Start-Process -FilePath $PowerShellExe -ArgumentList $arguments -WindowStyle Hidden -WorkingDirectory $ScriptRoot)
    return $false
}

function Initialize-UiAssemblies {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type @'
using System;
using System.Runtime.InteropServices;

public static class TrayNativeMethods
{
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern bool DestroyIcon(IntPtr handle);

    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@

    # Keep the tray icon and forms crisp on high-DPI displays.
    try {
        [void][TrayNativeMethods]::SetProcessDPIAware()
    } catch {
    }
}

function New-StatusIcon {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Stopped', 'Idle', 'Busy', 'Unknown')]
        [string]$State
    )

    $bitmap = New-Object System.Drawing.Bitmap 32, 32
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

    try {
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $baseBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(32, 61, 121))
        $graphics.FillEllipse($baseBrush, 1, 1, 30, 30)
        $baseBrush.Dispose()

        $font = New-Object System.Drawing.Font 'Segoe UI', 14, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
        $stringFormat = New-Object System.Drawing.StringFormat
        $stringFormat.Alignment = [System.Drawing.StringAlignment]::Center
        $stringFormat.LineAlignment = [System.Drawing.StringAlignment]::Center
        $graphics.DrawString('R', $font, [System.Drawing.Brushes]::White, (New-Object System.Drawing.RectangleF 0, 0, 24, 24), $stringFormat)
        $font.Dispose()
        $stringFormat.Dispose()

        switch ($State) {
            'Idle' {
                $markerColor = [System.Drawing.Color]::FromArgb(44, 173, 52)
            }
            'Busy' {
                $markerColor = [System.Drawing.Color]::FromArgb(255, 153, 0)
            }
            'Unknown' {
                $markerColor = [System.Drawing.Color]::FromArgb(120, 120, 120)
            }
            default {
                $markerColor = [System.Drawing.Color]::FromArgb(201, 48, 44)
            }
        }

        $markerBrush = New-Object System.Drawing.SolidBrush $markerColor
        $markerRect = New-Object System.Drawing.Rectangle 19, 19, 12, 12
        $graphics.FillEllipse($markerBrush, $markerRect)
        $markerBrush.Dispose()
        $graphics.DrawEllipse([System.Drawing.Pens]::White, $markerRect)

        if ($State -eq 'Stopped') {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White, 2)
            $graphics.DrawLine($pen, 22, 22, 28, 28)
            $pen.Dispose()
        } elseif ($State -eq 'Busy') {
            $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White, 2)
            $graphics.DrawArc($pen, 21, 21, 8, 8, 45, 270)
            $pen.Dispose()
        }

        $iconHandle = $bitmap.GetHicon()
        try {
            return [System.Drawing.Icon]::FromHandle($iconHandle).Clone()
        } finally {
            [TrayNativeMethods]::DestroyIcon($iconHandle) | Out-Null
        }
    } finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

function Start-TrayApplication {
    if (-not (Ensure-StaForTray)) {
        return
    }

    Initialize-UiAssemblies
    $trayMutex = Enter-SingleInstance -Name $TrayAppMutexName
    if (-not $trayMutex) {
        [System.Windows.Forms.MessageBox]::Show('Tray icon is already running. Only one instance is allowed.', 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        return
    }

    try {
        [System.Windows.Forms.Application]::EnableVisualStyles()
        [System.Windows.Forms.Application]::SetCompatibleTextRenderingDefault($false)

        # Global exception safety nets so a UI-thread failure is logged (and
        # visible) instead of silently killing the tray.
        $script:TrayThreadExceptionHandler = [System.Threading.ThreadExceptionEventHandler]{
            param($sender, $args)
            try {
                Write-HostLog -Message ("Tray thread exception: {0}" -f $args.Exception.ToString())
            } catch {
            }
        }
        [System.Windows.Forms.Application]::Add_ThreadException($script:TrayThreadExceptionHandler)

        $script:TrayUnhandledExceptionHandler = [System.UnhandledExceptionEventHandler]{
            param($sender, $args)
            try {
                Write-HostLog -Message ("Tray unhandled exception: {0}" -f $args.ExceptionObject.ToString())
            } catch {
            }
        }
        [System.AppDomain]::CurrentDomain.Add_UnhandledException($script:TrayUnhandledExceptionHandler)

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $statusItem = $contextMenu.Items.Add('Status: Loading...')
        $statusItem.Enabled = $false
        $dirItem = $contextMenu.Items.Add("Runner directory: $ScriptRoot")
        $dirItem.Enabled = $false
        [void]$contextMenu.Items.Add('-')
        $startItem = $contextMenu.Items.Add('Start runner')
        $stopItem = $contextMenu.Items.Add('Stop runner')
        $autostartItem = $contextMenu.Items.Add('Run on Windows startup')
        $autostartItem.CheckOnClick = $true
        $notifyItem = $contextMenu.Items.Add('Show state notifications')
        $notifyItem.CheckOnClick = $true
        $notifyItem.Checked = $true
        [void]$contextMenu.Items.Add('-')
        $openLatestRunnerLogItem = $contextMenu.Items.Add('Open latest runner log')
        $viewLatestRunnerLogItem = $contextMenu.Items.Add('Live view latest runner log')
        $viewRunCmdLiveLogItem = $contextMenu.Items.Add('Live view run.cmd output')
        $openRunCmdLiveLogItem = $contextMenu.Items.Add('Open run.cmd output file')
        $openHostLogItem = $contextMenu.Items.Add('Open tray host log')
        [void]$contextMenu.Items.Add('-')
        $openDocItem = $contextMenu.Items.Add('Open README.md')
        $openFolderItem = $contextMenu.Items.Add('Open runner folder')
        [void]$contextMenu.Items.Add('-')
        $exitItem = $contextMenu.Items.Add('Exit tray icon')

        $script:IconCache = @{}
        $script:LastState = $null

        $refreshUi = {
            try {
                $state = Get-RunnerState
                if ($state -eq 'Unknown') {
                    $statusItem.Text = 'Status: Unknown (elevation required)'
                    $startItem.Enabled = $false
                    $stopItem.Enabled = $false
                } else {
                    $statusItem.Text = "Status: $state"
                    $startItem.Enabled = $state -eq 'Stopped'
                    $stopItem.Enabled = $state -in @('Idle', 'Busy')
                }
                $autostartItem.Checked = Test-AutostartEnabled
                $notifyIcon.Text = "GitHub Runner: $state"

                if ($state -ne $script:LastState) {
                    if ($notifyItem.Checked -and ($null -ne $script:LastState)) {
                        $notifyIcon.ShowBalloonTip(3000, 'GitHub Runner', "Status changed: $script:LastState -> $state", [System.Windows.Forms.ToolTipIcon]::Info)
                    }
                    $script:LastState = $state
                }

                if (-not $script:IconCache.ContainsKey($state)) {
                    $script:IconCache[$state] = New-StatusIcon -State $state
                }
                $notifyIcon.Icon = $script:IconCache[$state]
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        }

        $notifyIcon.ContextMenuStrip = $contextMenu
        $notifyIcon.Visible = $true

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 5000
        $timer.Add_Tick($refreshUi)

        $startItem.Add_Click({
            try {
                $message = Start-RunnerControl
                [System.Windows.Forms.MessageBox]::Show($message, 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                & $refreshUi
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $stopItem.Add_Click({
            try {
                $confirm = [System.Windows.Forms.MessageBox]::Show('Stop the GitHub Actions runner? Any job currently running will be interrupted.', 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Warning)
                if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
                    return
                }

                $message = Stop-RunnerControl
                [System.Windows.Forms.MessageBox]::Show($message, 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
                & $refreshUi
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $autostartItem.Add_Click({
            try {
                Set-AutostartEnabled -Enabled $autostartItem.Checked
                & $refreshUi
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $openLatestRunnerLogItem.Add_Click({
            try {
                $path = Get-LatestRunnerDiagLogPath
                if ($path) {
                    Open-LogFile -Path $path
                    return
                }

                [System.Windows.Forms.MessageBox]::Show("No runner log file found in:`r`n$DiagRoot", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $viewLatestRunnerLogItem.Add_Click({
            try {
                Show-LogViewerWindow -PathResolver { Get-LatestRunnerDiagLogPath } -Title 'GitHub Runner - Live Log'
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $viewRunCmdLiveLogItem.Add_Click({
            try {
                Ensure-StateDirectory
                Show-LogViewerWindow -PathResolver { Get-RunCmdLiveLogPath } -Title 'GitHub Runner - run.cmd Live Output'
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $openRunCmdLiveLogItem.Add_Click({
            try {
                Ensure-StateDirectory
                if (Test-Path -LiteralPath $RunCmdLiveLogFile) {
                    Open-LogFile -Path $RunCmdLiveLogFile
                    return
                }

                [System.Windows.Forms.MessageBox]::Show("run.cmd output log is not available yet:`r`n$RunCmdLiveLogFile", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $openHostLogItem.Add_Click({
            try {
                Ensure-StateDirectory
                if (Test-Path -LiteralPath $HostLogFile) {
                    Open-LogFile -Path $HostLogFile
                    return
                }

                [System.Windows.Forms.MessageBox]::Show("Tray host log is not available yet:`r`n$HostLogFile", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $openDocItem.Add_Click({
            try {
                if (Test-Path -LiteralPath $ReadmePath) {
                    [void](Start-Process -FilePath $ReadmePath)
                } else {
                    [System.Windows.Forms.MessageBox]::Show('README.md was not found.', 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
                }
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $openFolderItem.Add_Click({
            try {
                [void](Start-Process -FilePath $ScriptRoot)
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $exitItem.Add_Click({
            try {
                $timer.Stop()
                $notifyIcon.Visible = $false
                [System.Windows.Forms.Application]::Exit()
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        $notifyIcon.Add_DoubleClick({
            try {
                $path = Get-LatestRunnerDiagLogPath
                if ($path) {
                    Open-LogFile -Path $path
                    return
                }

                $message = "GitHub Runner is currently $(Get-RunnerState)."
                [System.Windows.Forms.MessageBox]::Show($message, 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            } catch {
                Show-TrayError -ErrorRecord $_
            }
        })

        & $refreshUi
        $timer.Start()
        [System.Windows.Forms.Application]::Run()

        if ($script:IconCache) {
            foreach ($cacheIcon in $script:IconCache.Values) {
                $cacheIcon.Dispose()
            }
        }

        $timer.Dispose()
        $notifyIcon.Dispose()
        $contextMenu.Dispose()
    } finally {
        Exit-SingleInstance -Mutex $trayMutex
    }
}

try {
    if ($RunnerHost) {
        Invoke-RunnerHost
        exit 0
    }

    if ($Status) {
        Write-Output (Get-RunnerState)
        exit 0
    }

    if ($StartRunner) {
        Write-Output (Start-RunnerControl)
        exit 0
    }

    if ($StopRunner) {
        Write-Output (Stop-RunnerControl)
        exit 0
    }

    if ($LogPath) {
        $latestLogPath = Get-LatestRunnerDiagLogPath
        if ($latestLogPath) {
            Write-Output $latestLogPath
        }
        exit 0
    }

    if ($SelfTest) {
        Initialize-UiAssemblies
        Ensure-StateDirectory
        $icons = @(
            (New-StatusIcon -State 'Stopped'),
            (New-StatusIcon -State 'Idle'),
            (New-StatusIcon -State 'Busy'),
            (New-StatusIcon -State 'Unknown')
        )
        foreach ($icon in $icons) {
            $icon.Dispose()
        }

        # Probe whether the state directory is writable.
        $stateDirWritable = $false
        try {
            $probeFile = Join-Path $StateRoot '.selftest-probe'
            Set-Content -LiteralPath $probeFile -Value 'probe'
            Remove-IfExists -Path $probeFile
            $stateDirWritable = $true
        } catch {
        }

        [pscustomobject]@{
            ScriptPath = $ScriptPath
            RunCmdExists = Test-Path -LiteralPath $RunCmdPath
            BinDirExists = Test-Path -LiteralPath $BinRoot
            RunnerState = Get-RunnerState
            AutostartEnabled = Test-AutostartEnabled
            AutostartCommand = Get-AutostartCommand
            AutostartRegValueName = $AutostartValueName
            StateDirWritable = $stateDirWritable
            LatestRunnerLogPath = Get-LatestRunnerDiagLogPath
            RunCmdLiveLogPath = Get-RunCmdLiveLogPath
            StateRoot = $StateRoot
        } | Format-List | Out-String | Write-Output
        exit 0
    }

    Start-TrayApplication
} catch {
    # Early boot failures are invisible when launched from a hidden window.
    # Log them to a temp file and try to surface a message box.
    $bootLog = Join-Path $env:TEMP 'github-runner-trayicon-boot.log'
    try {
        Add-Content -LiteralPath $bootLog -Value ("[{0}] {1}" -f (Get-Date -Format o), $_.Exception.ToString())
    } catch {
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show("runner-tray.ps1 failed to start:`r`n$($_.Exception.Message)`r`n`r`nDetails were written to:`r`n$bootLog", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch {
    }

    exit 1
}
