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
$AutostartValueName = 'GitHubRunnerTrayIcon'
$PowerShellExe = Join-Path $PSHOME 'powershell.exe'
$sha1 = [System.Security.Cryptography.SHA1]::Create()
try {
    $pathHashBytes = $sha1.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($ScriptRoot.ToLowerInvariant()))
} finally {
    $sha1.Dispose()
}
$PathHash = ([System.BitConverter]::ToString($pathHashBytes)).Replace('-', '')
$TrayAppMutexName = "Global\GitHubRunnerTrayApp_$PathHash"
$RunnerHostMutexName = "Global\GitHubRunnerHost_$PathHash"

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

function Write-HostLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    Ensure-StateDirectory
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
    $all = Get-Process -Name 'Runner.Listener', 'Runner.Worker' -ErrorAction SilentlyContinue
    if (-not $all) {
        return @()
    }

    $matched = New-Object System.Collections.Generic.List[System.Diagnostics.Process]
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

        try {
            if ($process.Path -eq $expectedPath) {
                [void]$matched.Add($process)
            }
        } catch {
            # Keep filtering strict to this runner directory if the path is not readable.
        }
    }

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

    return $pidValue
}

function Get-AutostartCommand {
    return ('"{0}" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File "{1}"' -f $PowerShellExe, $ScriptPath)
}

function Test-AutostartEnabled {
    try {
        $currentValue = (Get-ItemProperty -Path $AutostartRegPath -Name $AutostartValueName -ErrorAction Stop).$AutostartValueName
        return [string]::IsNullOrWhiteSpace($currentValue) -eq $false
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
    $state = Get-RunnerState
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

    if (Wait-ForState -ExpectedState 'Idle' -TimeoutSeconds 20) {
        return 'Runner started.'
    }

    $lastLine = Get-LastHostLogLine
    if ($lastLine) {
        return "Runner start failed. Last host log: $lastLine"
    }

    return 'Runner start failed: no idle listener was detected within 20 seconds.'
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

            Add-Content -Path $RunCmdLiveLogFile -Value ("[{0}] Starting run.cmd" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
            $runCmdProcess = Start-Process -FilePath $RunCmdPath -WindowStyle Hidden -WorkingDirectory $ScriptRoot -RedirectStandardOutput $RunCmdLiveLogFile -PassThru
            Write-HostLog -Message ("run.cmd started with PID {0}." -f $runCmdProcess.Id)

            while (-not $runCmdProcess.HasExited) {
                if (Test-Path -LiteralPath $StopFlagFile) {
                    Write-HostLog -Message ("Stop signal detected; terminating run.cmd PID {0}." -f $runCmdProcess.Id)
                    Stop-RunnerProcesses
                    Stop-Process -Id $runCmdProcess.Id -Force
                    $runCmdProcess.WaitForExit()
                    break
                }

                Start-Sleep -Seconds 1
            }

            $exitCode = $runCmdProcess.ExitCode
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
}
'@
}

function New-StatusIcon {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Stopped', 'Idle', 'Busy')]
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

        $notifyIcon = New-Object System.Windows.Forms.NotifyIcon
        $contextMenu = New-Object System.Windows.Forms.ContextMenuStrip
        $statusItem = $contextMenu.Items.Add('Status: Loading...')
        $statusItem.Enabled = $false
        [void]$contextMenu.Items.Add('-')
        $startItem = $contextMenu.Items.Add('Start runner')
        $stopItem = $contextMenu.Items.Add('Stop runner')
        $autostartItem = $contextMenu.Items.Add('Run on Windows startup')
        $autostartItem.CheckOnClick = $true
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

        $script:CurrentIcon = $null

        $refreshUi = {
            $state = Get-RunnerState
            $statusItem.Text = "Status: $state"
            $startItem.Enabled = $state -eq 'Stopped'
            $stopItem.Enabled = $state -ne 'Stopped'
            $autostartItem.Checked = Test-AutostartEnabled
            $notifyIcon.Text = "GitHub Runner: $state"

            if ($script:CurrentIcon) {
                $script:CurrentIcon.Dispose()
            }

            $script:CurrentIcon = New-StatusIcon -State $state
            $notifyIcon.Icon = $script:CurrentIcon
        }

        $notifyIcon.ContextMenuStrip = $contextMenu
        $notifyIcon.Visible = $true

        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = 5000
        $timer.Add_Tick($refreshUi)

        $startItem.Add_Click({
            $message = Start-RunnerControl
            [System.Windows.Forms.MessageBox]::Show($message, 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            & $refreshUi
        })

        $stopItem.Add_Click({
            $message = Stop-RunnerControl
            [System.Windows.Forms.MessageBox]::Show($message, 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
            & $refreshUi
        })

        $autostartItem.Add_Click({
            Set-AutostartEnabled -Enabled $autostartItem.Checked
            & $refreshUi
        })

        $openLatestRunnerLogItem.Add_Click({
            $path = Get-LatestRunnerDiagLogPath
            if ($path) {
                Open-LogFile -Path $path
                return
            }

            [System.Windows.Forms.MessageBox]::Show("No runner log file found in:`r`n$DiagRoot", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        })

        $viewLatestRunnerLogItem.Add_Click({
            Show-LogViewerWindow -PathResolver { Get-LatestRunnerDiagLogPath } -Title 'GitHub Runner - Live Log'
        })

        $viewRunCmdLiveLogItem.Add_Click({
            Ensure-StateDirectory
            Show-LogViewerWindow -PathResolver { Get-RunCmdLiveLogPath } -Title 'GitHub Runner - run.cmd Live Output'
        })

        $openRunCmdLiveLogItem.Add_Click({
            Ensure-StateDirectory
            if (Test-Path -LiteralPath $RunCmdLiveLogFile) {
                Open-LogFile -Path $RunCmdLiveLogFile
                return
            }

            [System.Windows.Forms.MessageBox]::Show("run.cmd output log is not available yet:`r`n$RunCmdLiveLogFile", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        })

        $openHostLogItem.Add_Click({
            Ensure-StateDirectory
            if (Test-Path -LiteralPath $HostLogFile) {
                Open-LogFile -Path $HostLogFile
                return
            }

            [System.Windows.Forms.MessageBox]::Show("Tray host log is not available yet:`r`n$HostLogFile", 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        })

        $openDocItem.Add_Click({
            if (Test-Path -LiteralPath $ReadmePath) {
                [void](Start-Process -FilePath $ReadmePath)
            } else {
                [System.Windows.Forms.MessageBox]::Show('README.md was not found.', 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            }
        })

        $openFolderItem.Add_Click({
            [void](Start-Process -FilePath $ScriptRoot)
        })

        $exitItem.Add_Click({
            $timer.Stop()
            $notifyIcon.Visible = $false
            [System.Windows.Forms.Application]::Exit()
        })

        $notifyIcon.Add_DoubleClick({
            $message = "GitHub Runner is currently $(Get-RunnerState)."
            [System.Windows.Forms.MessageBox]::Show($message, 'GitHub Runner', [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
        })

        & $refreshUi
        $timer.Start()
        [System.Windows.Forms.Application]::Run()

        if ($script:CurrentIcon) {
            $script:CurrentIcon.Dispose()
        }

        $timer.Dispose()
        $notifyIcon.Dispose()
        $contextMenu.Dispose()
    } finally {
        Exit-SingleInstance -Mutex $trayMutex
    }
}

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
        (New-StatusIcon -State 'Busy')
    )
    foreach ($icon in $icons) {
        $icon.Dispose()
    }

    [pscustomobject]@{
        ScriptPath = $ScriptPath
        RunnerState = Get-RunnerState
        AutostartEnabled = Test-AutostartEnabled
        AutostartCommand = Get-AutostartCommand
        LatestRunnerLogPath = Get-LatestRunnerDiagLogPath
        RunCmdLiveLogPath = Get-RunCmdLiveLogPath
        StateRoot = $StateRoot
    } | Format-List | Out-String | Write-Output
    exit 0
}

Start-TrayApplication
