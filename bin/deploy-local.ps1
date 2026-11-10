<#
.SYNOPSIS
Build ai-memory from this checkout and deploy the build over the current
user's native Windows install.

.DESCRIPTION
The native Windows install is the one `install.ps1` / the release zip
creates: `ai-memory.exe` plus a sibling `hooks\` bundle under
%LOCALAPPDATA%\Programs\ai-memory, started at logon by the HKCU Run value
`ai-memory` (the hidden `service-host` supervisor).

This script replaces that binary with a locally built one:

  1. cargo build [--release] -p ai-memory-cli
  2. `ai-memory backup` into <target>\deploy-backups (skipped with -NoBackup)
  3. stops service-host (cooperative `<data-dir>\service-host.stop`, then a
     forced stop for anything still alive)
  4. swaps ai-memory.exe for the build, keeping the replaced binary as
     ai-memory.exe.prev; restores it if the new binary does not run
  5. refreshes the sibling hooks\ bundle from the checkout
  6. re-stages hooks and generated integrations with the new binary, then
     starts service-host and waits for the server to answer
     (-Setup runs `setup --yes` instead, re-wiring every detected agent)

It refuses anything that is not the native release layout: a Scoop, cargo,
Homebrew/Nix-prefix or Docker-wrapper install keeps its own updater.

The checkout can carry the same version string as the installed release, so
`--version` is not proof of the swap: the script compares SHA-256 instead and
prints the server's own report. Backups land under <target>\deploy-backups, and
the replaced binary is kept at ai-memory.exe.prev for rollback.

Rollback by hand: stop the service, then
  Move-Item <dir>\ai-memory.exe <dir>\ai-memory.exe.bad
  Move-Item <dir>\ai-memory.exe.prev <dir>\ai-memory.exe
  & <dir>\ai-memory.exe --data-dir <data> service-host

.PARAMETER SkipBuild
Use the existing build output instead of running cargo.

.PARAMETER DebugBuild
Build and deploy target\debug instead of target\release.

.PARAMETER Setup
Run `setup --yes` after the swap (re-wires detected agents, MCP entries and
skills, and starts the logon service) instead of only re-staging hooks.

.PARAMETER NoBackup
Skip the data-dir backup.

.PARAMETER NoRestart
Stop the service but do not start it again.

.PARAMETER KeepOld
Keep leftover ai-memory.old / ai-memory.exe.prev files.

.PARAMETER Plan
Print what the script detected and would do, then exit. Changes nothing.

.PARAMETER RepoRoot
Checkout to build. Defaults to the parent of this script's directory.

.PARAMETER InstallDir
Install directory holding ai-memory.exe. Defaults to the exe named by the
HKCU Run value, then to `ai-memory.exe` on PATH.

.PARAMETER DataDir
Data directory. Defaults to the Run value's --data-dir, then
%LOCALAPPDATA%\ai-memory.

.PARAMETER ConfigPath
Config file. Defaults to the Run value's --config, then <data-dir>\config.toml
when it exists.

.EXAMPLE
powershell -ExecutionPolicy Bypass -File bin\deploy-local.ps1

.EXAMPLE
powershell -ExecutionPolicy Bypass -File bin\deploy-local.ps1 -SkipBuild -Plan
#>
[CmdletBinding()]
param(
    [switch]$SkipBuild,
    [switch]$DebugBuild,
    [switch]$Setup,
    [switch]$NoBackup,
    [switch]$NoRestart,
    [switch]$KeepOld,
    [switch]$Plan,
    [string]$RepoRoot,
    [string]$InstallDir,
    [string]$DataDir,
    [string]$ConfigPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Keep a failure readable: Fail throws, and this prints just the message
# instead of a PowerShell stack for a step that ran before the swap.
trap {
    Write-Host ''
    Write-Host $_.Exception.Message -ForegroundColor Red
    exit 1
}

function Say([string]$Message) { Write-Host "deploy-local: $Message" }
function Warn([string]$Message) { Write-Warning "deploy-local: $Message" }
function Fail([string]$Message) { throw "deploy-local: error: $Message" }

# Split a Windows command line into its arguments, honouring double quotes.
function Split-CommandLine([string]$Line) {
    $tokens = New-Object System.Collections.Generic.List[string]
    $current = New-Object System.Text.StringBuilder
    $inQuotes = $false
    foreach ($ch in $Line.ToCharArray()) {
        if ($ch -eq '"') { $inQuotes = -not $inQuotes; continue }
        if (-not $inQuotes -and [char]::IsWhiteSpace($ch)) {
            if ($current.Length -gt 0) {
                $tokens.Add($current.ToString())
                [void]$current.Clear()
            }
            continue
        }
        [void]$current.Append($ch)
    }
    if ($current.Length -gt 0) { $tokens.Add($current.ToString()) }
    return ,$tokens.ToArray()
}

# The value that follows `--flag` (or `--flag=value`) in an argument list.
function Get-FlagValue([string[]]$Arguments, [string]$Name) {
    for ($i = 0; $i -lt $Arguments.Count; $i++) {
        $argument = $Arguments[$i]
        if ($argument -eq $Name -and $i + 1 -lt $Arguments.Count) { return $Arguments[$i + 1] }
        if ($argument -like "$Name=*") { return $argument.Substring($Name.Length + 1) }
    }
    return $null
}

# Windows PowerShell 5.1 turns a redirected stderr line from a native command
# into a terminating NativeCommandError while $ErrorActionPreference is Stop,
# even with `2>$null` or `*> $null`. The ai-memory client logs an INFO line to
# stderr on every run, so every probe below lowers the preference and decides
# success from the exit code instead.
function Invoke-Probe {
    param([string]$File, [string[]]$Arguments)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $File @Arguments 2>&1 | Out-Null
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}

# The binary's `--version` output and exit code, without the stderr hazard.
function Get-BinaryVersion([string]$File) {
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $text = (& $File --version 2>&1 | Out-String).Trim()
        return @{ ExitCode = $LASTEXITCODE; Text = $text }
    } finally {
        $ErrorActionPreference = $previous
    }
}

# SHA-256 without Get-FileHash. Windows PowerShell 5.1 can fail to autoload
# that cmdlet when its parent passed down PowerShell 7's PSModulePath, which
# holds a Microsoft.PowerShell.Utility build 5.1 cannot load.
function Get-Sha256([string]$Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    try {
        $sha = [System.Security.Cryptography.SHA256]::Create()
        try {
            $bytes = $sha.ComputeHash($stream)
            return ([BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
        } finally {
            $sha.Dispose()
        }
    } finally {
        $stream.Dispose()
    }
}

# Stop the logon service-host: ask it through the cooperative stop file, then
# force anything that is still alive after the timeout. A stale state file can
# name a pid Windows has since reused, so only ai-memory processes are touched.
function Stop-AiMemoryHost([string]$DataDir) {
    $stateFile = Join-Path $DataDir 'service-host.json'
    $stopFile = Join-Path $DataDir 'service-host.stop'
    if (-not (Test-Path -LiteralPath $stateFile)) {
        Say 'no service-host state file; nothing to stop'
        return
    }
    $state = $null
    try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { }
    if ($null -eq $state) {
        Warn "could not read $stateFile; leaving the service-host alone"
        return
    }
    $ids = @(@($state.supervisor_pid, $state.server_pid) |
        Where-Object { $_ } |
        Select-Object -Unique)
    if ($ids.Count -eq 0) {
        Say 'the state file names no live process; nothing to stop'
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        return
    }
    $live = @(Get-Process -Id $ids -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'ai-memory*' })
    if ($live.Count -eq 0) {
        Say 'service-host is not running'
        Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
        return
    }
    Say ('stopping service-host (pid ' + (($live | ForEach-Object { $_.Id }) -join ', ') + ')')
    New-Item -ItemType File -Force -Path $stopFile | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        $left = @(Get-Process -Id $ids -ErrorAction SilentlyContinue |
            Where-Object { $_.ProcessName -like 'ai-memory*' })
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    }
    $left = @(Get-Process -Id $ids -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessName -like 'ai-memory*' })
    if ($left.Count -gt 0) {
        $left | Stop-Process -Force
        Say 'force-stopped the remaining service-host processes'
    }
    Remove-Item -LiteralPath $stopFile, $stateFile -Force -ErrorAction SilentlyContinue
}

# Replace the exe with the build, keeping the old one as <exe>.prev and
# restoring it when the new binary cannot even print its version.
function Install-Binary([string]$Built, [string]$Exe) {
    $previous = "$Exe.prev"
    if (Test-Path -LiteralPath $previous) {
        try {
            Remove-Item -LiteralPath $previous -Force -ErrorAction Stop
        } catch {
            # A process that mapped the old binary (an MCP bridge outlives the
            # server) holds it open without delete sharing. Renaming still
            # works, so move it aside rather than failing the deploy; it is
            # pruned once that process exits.
            $stale = "$Exe.prev-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Move-Item -LiteralPath $previous -Destination $stale -Force
            Warn "the previous binary is locked by a running process; kept it at $stale"
        }
    }
    Move-Item -LiteralPath $Exe -Destination $previous -Force
    try {
        $copied = $false
        for ($attempt = 0; $attempt -lt 3 -and -not $copied; $attempt++) {
            try {
                Copy-Item -LiteralPath $Built -Destination $Exe -Force
                $copied = $true
            } catch {
                if ($attempt -eq 2) { throw }
                Start-Sleep -Milliseconds 500
            }
        }
        $probe = Get-BinaryVersion $Exe
        if ($probe.ExitCode -ne 0) {
            throw "the installed binary exited with $($probe.ExitCode) ($($probe.Text))"
        }
    } catch {
        Remove-Item -LiteralPath $Exe -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $previous) {
            Move-Item -LiteralPath $previous -Destination $Exe -Force
        }
        Fail "the new binary failed to run, so the previous binary was restored. $($_.Exception.Message)"
    }
    return [string]$probe.Text
}

# Replace the sibling hooks bundle whole, so scripts removed upstream do not
# linger. Staged beside the destination to stay on one volume, and restored on
# failure.
function Update-SiblingHooks([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source)) {
        Say "no hooks bundle in the checkout; leaving $Destination alone"
        return
    }
    $parent = Split-Path -Parent $Destination
    $staging = Join-Path $parent ('.hooks.staged-' + [Guid]::NewGuid().ToString('N'))
    $aside = Join-Path $parent ('.hooks.old-' + [Guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $Source -Destination $staging -Recurse -Force
    try {
        Move-Item -LiteralPath $Destination -Destination $aside
        Move-Item -LiteralPath $staging -Destination $Destination
    } catch {
        if (-not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $aside)) {
            Move-Item -LiteralPath $aside -Destination $Destination
        }
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    Remove-Item -LiteralPath $aside -Recurse -Force -ErrorAction SilentlyContinue
    Say "refreshed $Destination"
}

# Start the detached logon supervisor and wait until the server answers.
function Start-AiMemoryHost([string]$Exe, [string[]]$GlobalArgs, [string]$DataDir) {
    Say 'starting service-host'
    # Launch with Start-Process, not `&` in a pipeline. `service-host` starts a
    # detached supervisor which inherits the stdout handle of whatever launched
    # it; a PowerShell pipeline stays open until every holder of that pipe
    # closes it, so `& $Exe ... | Out-Null` never returns while the server runs.
    $arguments = @($GlobalArgs) + @('service-host')
    $quoted = @(foreach ($argument in $arguments) {
        if ($argument -match '[\s"]') { '"' + ($argument -replace '"', '\"') + '"' } else { $argument }
    })
    Start-Process -FilePath $Exe -ArgumentList ($quoted -join ' ') -WindowStyle Hidden | Out-Null
    $deadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $deadline) {
        # Exit 0 means /admin/status answered, i.e. the server is up.
        if ((Invoke-Probe $Exe (@($GlobalArgs) + @('status'))) -eq 0) {
            Say 'the server answers'
            return
        }
        Start-Sleep -Milliseconds 500
    }
    Fail "the server did not answer within 60s. Check $DataDir\logs, then run: `"$Exe`" --data-dir `"$DataDir`" status"
}

if (-not $RepoRoot) { $RepoRoot = Split-Path -Parent $PSScriptRoot }
$RepoRoot = [IO.Path]::GetFullPath($RepoRoot)
$manifest = Join-Path $RepoRoot 'Cargo.toml'
if (-not (Test-Path -LiteralPath $manifest)) {
    Fail "no Cargo.toml under $RepoRoot; run this from the checkout or pass -RepoRoot"
}

# The logon entry names the binary the install actually runs, with its data
# dir and config. Prefer it over PATH, which may hold a second copy.
$runLine = $null
try {
    $runLine = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
        -Name 'ai-memory' -ErrorAction Stop).'ai-memory'
} catch { }

$exe = $null
$runArguments = @()
if ($runLine) {
    $tokens = Split-CommandLine ([string]$runLine)
    if ($tokens.Count -gt 0) {
        $exe = $tokens[0]
        if ($tokens.Count -gt 1) { $runArguments = @($tokens[1..($tokens.Count - 1)]) }
    }
}
if ($InstallDir) { $exe = Join-Path ([IO.Path]::GetFullPath($InstallDir)) 'ai-memory.exe' }
if (-not $exe) {
    $command = Get-Command 'ai-memory.exe' -ErrorAction SilentlyContinue
    if ($command) { $exe = $command.Source }
}
if (-not $exe) {
    Fail 'could not find an installed ai-memory.exe (no HKCU Run entry and nothing on PATH). Install one first or pass -InstallDir'
}
$exe = [IO.Path]::GetFullPath($exe)
if (-not (Test-Path -LiteralPath $exe)) { Fail "no ai-memory.exe at $exe" }
$installDir = Split-Path -Parent $exe

# The native release layout is the only one this script may replace. A Scoop,
# cargo, Homebrew/Nix-prefix or Docker-wrapper install owns its own updater.
$siblingHooks = Join-Path $installDir 'hooks'
if (-not (Test-Path -LiteralPath $siblingHooks)) {
    Fail "refusing to deploy into ${installDir}: there is no hooks\ directory beside the binary, so it is not the native release layout (install.ps1 / ai-memory-windows-x86_64.zip). A Scoop, cargo, Homebrew or Docker-wrapper install keeps its own updater"
}
if ($installDir -match '(?i)\\scoop\\apps\\') {
    Fail "refusing to overwrite a Scoop install at $installDir; run `scoop update ai-memory` instead"
}
if ($installDir -match '(?i)\\.cargo\\bin$') {
    Fail "refusing to overwrite a cargo install at $installDir; run `cargo install --path` again instead"
}
if ((Split-Path -Leaf $installDir) -eq 'bin') {
    Fail "refusing to overwrite a prefix install at $installDir (Homebrew/Nix style); use that package manager instead"
}

if (-not $DataDir) {
    $DataDir = Get-FlagValue $runArguments '--data-dir'
    if (-not $DataDir) { $DataDir = Join-Path $env:LOCALAPPDATA 'ai-memory' }
}
$DataDir = [IO.Path]::GetFullPath($DataDir)
if (-not (Test-Path -LiteralPath $DataDir)) {
    Fail "the data dir $DataDir does not exist; is ai-memory initialised for this user?"
}

if (-not $ConfigPath) {
    $ConfigPath = Get-FlagValue $runArguments '--config'
    if (-not $ConfigPath) {
        $candidate = Join-Path $DataDir 'config.toml'
        if (Test-Path -LiteralPath $candidate) { $ConfigPath = $candidate }
    }
}
if ($ConfigPath) {
    $ConfigPath = [IO.Path]::GetFullPath($ConfigPath)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { Fail "the config file $ConfigPath does not exist" }
}

# Global options go before the subcommand, in the same order the Run value uses.
$globalArgs = @('--data-dir', $DataDir)
if ($ConfigPath) { $globalArgs += @('--config', $ConfigPath) }

$targetDir = $env:CARGO_TARGET_DIR
if ($targetDir) {
    if (-not [IO.Path]::IsPathRooted($targetDir)) { $targetDir = Join-Path $RepoRoot $targetDir }
    $targetDir = [IO.Path]::GetFullPath($targetDir)
} else {
    $targetDir = Join-Path $RepoRoot 'target'
}
$buildProfile = if ($DebugBuild) { 'debug' } else { 'release' }
$built = Join-Path (Join-Path $targetDir $buildProfile) 'ai-memory.exe'

if ($Plan) {
    $running = 'not running'
    $stateFile = Join-Path $DataDir 'service-host.json'
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
            $ids = @(@($state.supervisor_pid, $state.server_pid) | Where-Object { $_ })
            $live = if ($ids.Count -gt 0) {
                @(Get-Process -Id $ids -ErrorAction SilentlyContinue |
                    Where-Object { $_.ProcessName -like 'ai-memory*' })
            } else { @() }
            if ($live.Count -gt 0) { $running = 'pids ' + (($live | ForEach-Object { $_.Id }) -join ', ') }
        } catch { }
    }
    Say "checkout:    $RepoRoot"
    Say "install dir: $installDir"
    Say "binary:      $exe"
    Say "data dir:    $DataDir"
    Say "config:      $(if ($ConfigPath) { $ConfigPath } else { '(default)' })"
    Say "build:       $built ($buildProfile)"
    Say "service:     $running"
    Say 'nothing was changed (-Plan)'
    return
}

if (-not $SkipBuild) {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    if (-not $cargo) { Fail 'cargo is not on PATH; install the toolchain pinned in rust-toolchain.toml' }
    $cargoArgs = @('build', '-p', 'ai-memory-cli')
    if (-not $DebugBuild) { $cargoArgs += '--release' }
    $cargoArgs += @('--manifest-path', $manifest)
    Say ('building: cargo ' + ($cargoArgs -join ' '))
    Push-Location $RepoRoot
    try {
        & cargo @cargoArgs
        if ($LASTEXITCODE -ne 0) { Fail "cargo build failed with exit code $LASTEXITCODE" }
    } finally {
        Pop-Location
    }
}
if (-not (Test-Path -LiteralPath $built)) {
    Fail "expected the build at $built; check -DebugBuild / CARGO_TARGET_DIR and run without -SkipBuild"
}
$builtProbe = Get-BinaryVersion $built
if ($builtProbe.ExitCode -ne 0) { Fail "the fresh build does not run ($built): $($builtProbe.Text)" }
Say "built $($builtProbe.Text)"

if (-not $NoBackup) {
    $backupDir = Join-Path $targetDir 'deploy-backups'
    New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
    $backup = Join-Path $backupDir ('ai-memory-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.tar.gz')
    Say "backing up the data dir to $backup"
    & $exe @globalArgs backup --to $backup | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Warn 'the backup failed (server unreachable?); continuing without it. Re-run with the service up, or pass -NoBackup'
    } else {
        Say 'backup written'
    }
}

Stop-AiMemoryHost $DataDir

$installedVersion = $null
try {
    $installedVersion = Install-Binary $built $exe
    Say "installed $installedVersion"

    Update-SiblingHooks (Join-Path $RepoRoot 'hooks') $siblingHooks

    if (-not $NoRestart) {
        if ($Setup) {
            Say 'running setup --yes (re-wires detected agents and starts the service)'
            & $exe @globalArgs setup --yes
            if ($LASTEXITCODE -ne 0) {
                Fail 'setup failed; the new binary is installed but the service may be stopped. Check the data-dir logs, then run setup again'
            }
        } else {
            # The same refresh `ai-memory upgrade` runs: re-stage the hook
            # scripts and generated integrations for every agent already
            # staged under the data dir, rendered by the new binary.
            Say 'refreshing staged hooks and generated integrations'
            & $exe @globalArgs upgrade-refresh-hooks
            if ($LASTEXITCODE -ne 0) {
                Fail 'the hook refresh failed; the new binary is installed but the service is stopped. Run `upgrade-refresh-hooks` again once the cause is fixed'
            }
            Start-AiMemoryHost $exe $globalArgs $DataDir
        }
    } else {
        Say 'not starting the service (-NoRestart)'
    }
} catch {
    Write-Host ''
    Write-Host "deploy-local: $($_.Exception.Message)" -ForegroundColor Red
    if (Test-Path -LiteralPath "$exe.prev") {
        Write-Host "deploy-local: the previous binary is kept at $exe.prev"
        Write-Host 'deploy-local: rollback: stop service-host, move ai-memory.exe aside, move ai-memory.exe.prev back, then start service-host'
    }
    exit 1
}

$installedHash = Get-Sha256 $exe
$builtHash = Get-Sha256 $built
if ($installedHash -ne $builtHash) {
    Warn "the installed binary does not match the build output; check $exe"
}

if (-not $KeepOld) {
    $staleOld = Join-Path $installDir 'ai-memory.old'
    if (Test-Path -LiteralPath $staleOld) {
        try {
            Remove-Item -LiteralPath $staleOld -Force -ErrorAction Stop
            Say 'removed the leftover ai-memory.old'
        } catch {
            Warn "could not remove $staleOld (still mapped by a running process?); pass -KeepOld to skip this"
        }
    }
    # Binaries moved aside while a process still mapped them. A locked one
    # cannot be deleted yet; the next run after that process exits reclaims it.
    Get-ChildItem -LiteralPath $installDir -Filter 'ai-memory.exe.prev-*' -File -ErrorAction SilentlyContinue |
        ForEach-Object {
            try { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop } catch { }
        }
}

# MCP bridges are spawned by the agent clients, not by service-host, so they
# keep the previous binary until each client restarts.
$bridges = @(Get-CimInstance Win32_Process -Filter "Name = 'ai-memory.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like '*mcp-bridge*' })
if ($bridges.Count -gt 0) {
    Warn "$($bridges.Count) mcp-bridge process(es) still run the previous binary; restart Claude Code, Codex, or whichever client owns them to load this build"
}

Say "done: $exe"
if (-not $NoRestart) {
    & $exe @globalArgs status
    if ($LASTEXITCODE -ne 0) {
        Warn "the server did not answer status; check $DataDir\logs"
        exit 1
    }
}
