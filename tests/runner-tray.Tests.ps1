# Pester tests for runner-tray.ps1.
#
# Each test is fully self-contained: it loads the script's function
# definitions (without executing the tray or the CLI dispatch) directly in
# its own It scope. No functions or variables are shared through the file
# scope, because on CI (real Pester 5 module from PSGallery) neither
# file-top-level functions nor top-level $script: variables are visible
# inside It blocks (verified with a probe test).

Describe 'Autostart command' {
    It 'returns a fully quoted command line' {
        # --- load the script's functions into this It scope ---
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        $cmd = Get-AutostartCommand
        $cmd | Should -Match '^"[^"]+" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -Sta -File ".+"$'
    }
}

Describe 'Autostart registry' {
    It 'writes, reads and clears the autostart value' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        $testKey = Join-Path 'HKCU:\Software' 'NEVSTOP-LAB-PesterTest'
        $AutostartRegPath = $testKey
        try {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -Path $testKey -Force | Out-Null

            Set-AutostartEnabled -Enabled $true
            $stored = (Get-ItemProperty -Path $testKey -Name $AutostartValueName -ErrorAction Stop).$AutostartValueName
            $stored | Should -BeExactly (Get-AutostartCommand)
            Test-AutostartEnabled | Should -BeTrue

            Set-AutostartEnabled -Enabled $false
            Test-AutostartEnabled | Should -BeFalse
        } finally {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports disabled when the stored command is stale' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        $testKey = Join-Path 'HKCU:\Software' 'NEVSTOP-LAB-PesterTest'
        $AutostartRegPath = $testKey
        try {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -Path $testKey -Force | Out-Null
            New-ItemProperty -Path $testKey -Name $AutostartValueName -PropertyType String -Value 'C:\stale\runner-tray.ps1' -Force | Out-Null

            Test-AutostartEnabled | Should -BeFalse
        } finally {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reports enabled when a matching legacy value exists' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        $testKey = Join-Path 'HKCU:\Software' 'NEVSTOP-LAB-PesterTest'
        $AutostartRegPath = $testKey
        try {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -Path $testKey -Force | Out-Null
            New-ItemProperty -Path $testKey -Name $LegacyAutostartValueName -PropertyType String -Value (Get-AutostartCommand) -Force | Out-Null

            Test-AutostartEnabled | Should -BeTrue
        } finally {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'removes the legacy value when enabling autostart' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        $testKey = Join-Path 'HKCU:\Software' 'NEVSTOP-LAB-PesterTest'
        $AutostartRegPath = $testKey
        try {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
            New-Item -Path $testKey -Force | Out-Null
            New-ItemProperty -Path $testKey -Name $LegacyAutostartValueName -PropertyType String -Value (Get-AutostartCommand) -Force | Out-Null

            Set-AutostartEnabled -Enabled $true
            $legacy = Get-ItemProperty -Path $testKey -Name $LegacyAutostartValueName -ErrorAction SilentlyContinue
            $current = Get-ItemProperty -Path $testKey -Name $AutostartValueName -ErrorAction SilentlyContinue
            $null -eq $legacy | Should -BeTrue
            $null -ne $current | Should -BeTrue
        } finally {
            Remove-Item -Path $testKey -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Runner state detection' {
    It 'reports Stopped when no runner processes are matched' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        function Get-RunnerProcesses { return @() }
        Get-RunnerState | Should -BeExactly 'Stopped'
    }

    It 'reports Busy when a worker process is matched' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        function Get-RunnerProcesses {
            return @(
                [pscustomobject]@{ ProcessName = 'Runner.Worker'; Id = 1 },
                [pscustomobject]@{ ProcessName = 'Runner.Listener'; Id = 2 }
            )
        }
        Get-RunnerState | Should -BeExactly 'Busy'
    }

    It 'reports Idle when only the listener is matched' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        function Get-RunnerProcesses {
            return @([pscustomobject]@{ ProcessName = 'Runner.Listener'; Id = 2 })
        }
        Get-RunnerState | Should -BeExactly 'Idle'
    }

    It 'reports Unknown when a same-named process cannot be verified' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        # Seed the unresolved list the real function maintains. $script: refers
        # to the same scope for every statement executed inside this It block.
        [void](Get-RunnerProcesses)
        $script:UnresolvedRunnerProcesses = @([pscustomobject]@{ ProcessName = 'Runner.Listener'; Id = 99 })
        function Get-RunnerProcesses { return @() }
        Get-RunnerState | Should -BeExactly 'Unknown'
    }
}

Describe 'Log rotation' {
    It 'rolls a log file over to <name>.1 past the threshold' {
        $dir = Get-Location
        while ($null -ne $dir -and -not (Test-Path -LiteralPath (Join-Path $dir 'runner-tray.ps1'))) {
            $dir = Split-Path -Parent $dir
        }
        if ($null -eq $dir) { throw 'runner-tray.ps1 not found above the current directory.' }
        $scriptPath = Join-Path $dir 'runner-tray.ps1'
        $content = Get-Content -LiteralPath $scriptPath -Raw
        $content = $content -replace '(?ms)^\[CmdletBinding\(\)\]\s*param\([^)]*\)\s*', ''
        $cut = $content.IndexOf('if ($RunnerHost) {')
        if ($cut -lt 0) { throw 'dispatch marker not found in runner-tray.ps1' }
        $content = $content.Substring(0, $cut).TrimEnd()
        if ($content.EndsWith('try {')) { $content = $content.Substring(0, $content.Length - 5).TrimEnd() }
        $escapedPath = $scriptPath.Replace("'", "''")
        $content = $content.Replace('$ScriptPath = $PSCommandPath', "`$ScriptPath = '$escapedPath'")
        Invoke-Expression $content

        $dir = Join-Path ([System.IO.Path]::GetTempPath()) ('traytest-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        try {
            $log = Join-Path $dir 'host.log'
            Set-Content -LiteralPath $log -Value ('x' * 1000)
            Test-LogRollover -Path $log -MaxBytes 100
            Test-Path -LiteralPath ($log + '.1') | Should -BeTrue
            Test-Path -LiteralPath $log | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
