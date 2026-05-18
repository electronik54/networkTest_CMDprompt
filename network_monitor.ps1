# ============================
# Network Monitor (Async Multi-Target, Per-Target Summaries)
# - Default Google DNS hard-coded
# - Honors config.json "ignoreGoogleDns" key
# ============================

# --- Configuration ---
$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath     = Join-Path $scriptDir 'config.json'
$defaultPrimary = [PSCustomObject]@{ name = 'Google DNS'; targetHost = '8.8.8.8' }

# Single hashtable holding all per-target counters and capped history lists
$state   = @{}
$counter = 0

# --- Helpers ---

# Prints a message with a specified console color.
function Write-Colored {
    param($text, $color)
    Write-Host $text -ForegroundColor $color
}

# Returns a text/color tag for a value based on threshold ranges.
function Get-RateTag {
    param($value, $good, $ok)
    if ($value -le $good)   { return @{ text = 'GOOD';     color = 'Green'  } }
    elseif ($value -le $ok) { return @{ text = 'BAD';      color = 'Yellow' } }
    else                    { return @{ text = 'VERY BAD'; color = 'Red'    } }
}

# Writes one formatted per-target summary line with colored quality tags.
function Write-TargetLine {
    param($name, $address, $avgLatency, $avgJitter, $finalLoss)
    $latTag  = Get-RateTag $avgLatency 40 80
    $jitTag  = Get-RateTag $avgJitter  15 30
    $lossTag = Get-RateTag $finalLoss  0  1
    Write-Host ("{0} ({1}) | T:{2}ms " -f $name, $address, $avgLatency) -NoNewline
    Write-Host $latTag.text  -ForegroundColor $latTag.color  -NoNewline
    Write-Host ("  J:{0}ms " -f $avgJitter) -NoNewline
    Write-Host $jitTag.text  -ForegroundColor $jitTag.color  -NoNewline
    Write-Host ("  L:{0}% " -f $finalLoss) -NoNewline
    Write-Host $lossTag.text -ForegroundColor $lossTag.color
}

# Resolves a usable speedtest.exe path.
# Order: configured path -> local app folder -> PATH -> download to local app folder.
function Ensure-SpeedtestCli {
    param(
        [string]$PreferredPath,
        [string]$DownloadUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip",
        [bool]$AutoInstall = $true
    )

    $appToolsDir = Join-Path $env:LOCALAPPDATA 'network-monitor\tools'
    $localExe    = Join-Path $appToolsDir 'speedtest.exe'
    $bundledExe  = Join-Path $scriptDir 'speedtest.exe'

    if (-not [string]::IsNullOrWhiteSpace($PreferredPath) -and (Test-Path $PreferredPath)) {
        return (Resolve-Path $PreferredPath).Path
    }

    if (Test-Path $bundledExe) {
        return $bundledExe
    }

    if (Test-Path $localExe) {
        return $localExe
    }

    $speedtestCmd = Get-Command speedtest.exe -ErrorAction SilentlyContinue
    if ($speedtestCmd) {
        return $speedtestCmd.Source
    }

    if (-not $AutoInstall) {
        return $null
    }

    try {
        Write-Colored "> speedtest.exe not found. Downloading Speedtest CLI..." Yellow
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        New-Item -ItemType Directory -Force -Path $appToolsDir | Out-Null

        $zipPath     = Join-Path $appToolsDir 'speedtest-cli.zip'
        $extractPath = Join-Path $appToolsDir 'speedtest-cli-extract'

        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing
        if (Test-Path $extractPath) { Remove-Item $extractPath -Recurse -Force }
        Expand-Archive -Path $zipPath -DestinationPath $extractPath -Force

        $exe = Get-ChildItem -Path $extractPath -Recurse -Filter 'speedtest.exe' -File | Select-Object -First 1
        if ($null -eq $exe) {
            Write-Colored "> Speedtest CLI download succeeded but speedtest.exe was not found in archive." Red
            return $null
        }

        Copy-Item -Path $exe.FullName -Destination $localExe -Force
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
        Write-Colored ("> Speedtest CLI installed at {0}" -f $localExe) Green
        return $localExe
    }
    catch {
        Write-Colored ("> Failed to install Speedtest CLI: {0}" -f $_) Red
        return $null
    }
}

# Runs Ookla speedtest.exe and parses JSON output.
function Invoke-Speedtest {
    param(
        [string]$ServerId,
        [string]$SpeedtestExePath
    )

    $result = [PSCustomObject]@{ Download = 0.0; Upload = 0.0; ExitCode = 0; RateLimited = $false; UsedServerId = $null }
    if ([string]::IsNullOrWhiteSpace($SpeedtestExePath) -or -not (Test-Path $SpeedtestExePath)) {
        $result.ExitCode = -1
        Write-Host "> Speedtest failed: speedtest.exe not available."
        return $result
    }

    $args = @('--accept-license', '--accept-gdpr', '--format=json')
    $result.UsedServerId = $ServerId
    $label = 'auto-selected server'
    if (-not [string]::IsNullOrWhiteSpace($ServerId)) {
        $args += ("--server-id={0}" -f $ServerId)
        $label = "server id $ServerId"
    }

    try {
        Write-Host ("> Running speedtest.exe ({0})..." -f $label) -NoNewline
        $raw = & $SpeedtestExePath @args 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) {
            $rawText = ($raw -join ' ')
            $result.ExitCode = $exitCode
            if ($exitCode -eq 429 -or $rawText -match 'Too many requests|Limit reached') {
                $result.RateLimited = $true
            }
            Write-Host ("`r> Speedtest failed: speedtest.exe exited with code {0}. Output: {1}             " -f $exitCode, $rawText)
            return $result
        }

        $json = ($raw -join "`n") | ConvertFrom-Json
        if ($null -eq $json.download -or $null -eq $json.upload) {
            $result.ExitCode = -2
            Write-Host "`r> Speedtest failed: output missing download/upload fields             "
            return $result
        }

        $result.Download = [math]::Round((([double]$json.download.bandwidth) * 8) / 1MB, 2)
        $result.Upload   = [math]::Round((([double]$json.upload.bandwidth) * 8) / 1MB, 2)
        Write-Host "`r> Speedtest complete                    "
    }
    catch {
        $result.ExitCode = -3
        Write-Host ("`r> Speedtest failed: {0}             " -f $_)
    }

    return $result
}

# Loads targets from config.json and applies ignoreGoogleDns/default-target rules.
# Returns a result object with Targets array and parsed Config for reuse (avoids double file read).
function Load-Config {
    param($path)

    if (-not (Test-Path $path)) {
        Write-Colored ("Config not found - using default target {0}" -f $defaultPrimary.targetHost) Yellow
        return [PSCustomObject]@{ Targets = @($defaultPrimary); Config = $null }
    }

    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json

        $ignoreGoogle = $false
        if ($null -ne $json.pingTest -and $null -ne $json.pingTest.ignoreGoogleDns) {
            try { $ignoreGoogle = [bool]$json.pingTest.ignoreGoogleDns } catch {}
        }
        elseif ($null -ne $json.ignoreGoogleDns) {
            # Backward compatibility with legacy top-level key
            try { $ignoreGoogle = [bool]$json.ignoreGoogleDns } catch {}
        }

        $list = [System.Collections.Generic.List[object]]::new()
        $pingTargets = $null
        if ($null -ne $json.pingTest -and $null -ne $json.pingTest.pingTargets) {
            $pingTargets = $json.pingTest.pingTargets
        }
        elseif ($null -ne $json.pingTargets) {
            # Backward compatibility with legacy top-level key
            $pingTargets = $json.pingTargets
        }

        if ($null -ne $pingTargets) {
            foreach ($t in $pingTargets) {
                if (-not $t.host) { continue }
                $name = if ($t.name) { $t.name } else { $t.host }
                if ($ignoreGoogle -and ($t.host -eq $defaultPrimary.targetHost -or $name -match 'Google\s*DNS')) { continue }
                $list.Add([PSCustomObject]@{ name = $name; targetHost = $t.host })
            }
        }

        if (-not $ignoreGoogle) {
            $alreadyPresent = $list | Where-Object { $_.targetHost -eq $defaultPrimary.targetHost }
            if (-not $alreadyPresent) {
                $list.Insert(0, $defaultPrimary)
                Write-Colored ("Auto-added {0} ({1}) because ignoreGoogleDns is false" -f $defaultPrimary.name, $defaultPrimary.targetHost) Cyan
            }
        }

        if ($list.Count -eq 0) {
            if ($ignoreGoogle) {
                Write-Colored "Config contains no targets and ignoreGoogleDns is true. No targets to monitor. Exiting." Red
                return [PSCustomObject]@{ Targets = @(); Config = $json }
            }
            Write-Colored ("Config contains no targets - using default target {0}" -f $defaultPrimary.targetHost) Yellow
            return [PSCustomObject]@{ Targets = @($defaultPrimary); Config = $json }
        }

        return [PSCustomObject]@{ Targets = $list.ToArray(); Config = $json }
    }
    catch {
        Write-Colored ("Config parse failed - using default target {0}" -f $defaultPrimary.targetHost) Red
        return [PSCustomObject]@{ Targets = @($defaultPrimary); Config = $null }
    }
}

# Starts an async ICMP ping; returns the Ping instance and its Task.
# Caller must call Dispose() on the Ping instance after the Task completes.
function Start-PingAsync {
    param([string]$targetHost, [int]$timeoutMs = 1000)
    $ping = [System.Net.NetworkInformation.Ping]::new()
    return $ping, $ping.SendPingAsync($targetHost, $timeoutMs)
}

# --- Bootstrap: load config once, deduplicate targets ---
$cfgResult = Load-Config -path $configPath
$targets   = $cfgResult.Targets
$cfg       = $cfgResult.Config
$cfgResult = $null   # release wrapper

if ($null -eq $targets -or $targets.Count -eq 0) {
    Write-Colored "No targets configured. Exiting." Red
    exit 1
}

# Deduplicate by address using a HashSet (O(1) lookup, no extra hashtable overhead)
$seen    = [System.Collections.Generic.HashSet[string]]::new()
$targets = @($targets | Where-Object { $seen.Add($_.targetHost) })
$seen    = $null   # free immediately

if ($targets.Count -eq 0) {
    Write-Colored "No targets remaining after deduplication. Exiting." Red
    exit 1
}

# Read test settings from the already-parsed config (no second file read)
$doPingTest      = $true
$doSpeedtest     = $false
$monitorInterval = 60
$speedtestServerId = $null
$speedtestInterval = 600
$speedtestRunOnStart = $false
$speedtestRateLimitCooldownSeconds = 1800
$speedtestCliPath = $null
$speedtestCliDownloadUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
$speedtestAutoInstallCli = $true
if ($null -ne $cfg -and $null -ne $cfg.speedtest) {
    if ($null -ne $cfg.speedtest.enabled) { try { $doSpeedtest = [bool]$cfg.speedtest.enabled } catch {} }
}

if ($null -ne $cfg -and $null -ne $cfg.tests) {
    # Compatibility fallback for older schema key
    if ($null -ne $cfg.tests.doSpeedtest) { try { $doSpeedtest = [bool]$cfg.tests.doSpeedtest } catch {} }

    # Compatibility fallback for older schema keys
    if ($null -ne $cfg.tests.doPingTest) {
        try { $doPingTest = [bool]$cfg.tests.doPingTest } catch {}
    }
    if ($null -ne $cfg.tests.monitorIntervalSecond -and [int]$cfg.tests.monitorIntervalSecond -gt 0) {
        $monitorInterval = [int]$cfg.tests.monitorIntervalSecond
    }

    # Compatibility fallback for intermediate schema (tests.pingTest)
    if ($null -ne $cfg.tests.pingTest) {
        if ($null -ne $cfg.tests.pingTest.enabled) {
            try { $doPingTest = [bool]$cfg.tests.pingTest.enabled } catch {}
        }
        if ($null -ne $cfg.tests.pingTest.monitorIntervalSecond -and [int]$cfg.tests.pingTest.monitorIntervalSecond -gt 0) {
            $monitorInterval = [int]$cfg.tests.pingTest.monitorIntervalSecond
        }
    }
}
elseif ($null -ne $cfg -and $null -ne $cfg.log) {
    # Backward compatibility with legacy "log" key
    if ($null -ne $cfg.log.doPingTest)  { try { $doPingTest  = [bool]$cfg.log.doPingTest  } catch {} }
    if ($null -ne $cfg.log.doSpeedtest) { try { $doSpeedtest = [bool]$cfg.log.doSpeedtest } catch {} }
    if ($null -ne $cfg.log.monitorIntervalSecond -and [int]$cfg.log.monitorIntervalSecond -gt 0) {
        $monitorInterval = [int]$cfg.log.monitorIntervalSecond
    }
}

# Current schema: top-level pingTest
if ($null -ne $cfg -and $null -ne $cfg.pingTest) {
    if ($null -ne $cfg.pingTest.enabled) {
        try { $doPingTest = [bool]$cfg.pingTest.enabled } catch {}
    }
    if ($null -ne $cfg.pingTest.monitorIntervalSecond -and [int]$cfg.pingTest.monitorIntervalSecond -gt 0) {
        $monitorInterval = [int]$cfg.pingTest.monitorIntervalSecond
    }
}
if ($null -ne $cfg -and $null -ne $cfg.speedtest) {
    if ($null -ne $cfg.speedtest.serverId) {
        $sid = [string]$cfg.speedtest.serverId
        if (-not [string]::IsNullOrWhiteSpace($sid)) { $speedtestServerId = $sid }
    }
    if ($null -ne $cfg.speedtest.summaryAfterSeconds -and [int]$cfg.speedtest.summaryAfterSeconds -gt 0) {
        $speedtestInterval = [int]$cfg.speedtest.summaryAfterSeconds
    }
    elseif ($null -ne $cfg.speedtest.intervalSecond -and [int]$cfg.speedtest.intervalSecond -gt 0) {
        # Backward compatibility with old key name
        $speedtestInterval = [int]$cfg.speedtest.intervalSecond
    }
    if ($null -ne $cfg.speedtest.runOnStart) {
        try { $speedtestRunOnStart = [bool]$cfg.speedtest.runOnStart } catch {}
    }
    if ($null -ne $cfg.speedtest.rateLimitCooldownSeconds -and [int]$cfg.speedtest.rateLimitCooldownSeconds -gt 0) {
        $speedtestRateLimitCooldownSeconds = [int]$cfg.speedtest.rateLimitCooldownSeconds
    }
    elseif ($null -ne $cfg.speedtest.cooldownAfter429Second -and [int]$cfg.speedtest.cooldownAfter429Second -gt 0) {
        # Backward compatibility with old key name
        $speedtestRateLimitCooldownSeconds = [int]$cfg.speedtest.cooldownAfter429Second
    }

    if ($null -ne $cfg.speedtest.cliPath) {
        $p = [string]$cfg.speedtest.cliPath
        if (-not [string]::IsNullOrWhiteSpace($p)) { $speedtestCliPath = $p }
    }
    if ($null -ne $cfg.speedtest.cliDownloadUrl) {
        $u = [string]$cfg.speedtest.cliDownloadUrl
        if (-not [string]::IsNullOrWhiteSpace($u)) { $speedtestCliDownloadUrl = $u }
    }
    if ($null -ne $cfg.speedtest.autoInstallCli) {
        try { $speedtestAutoInstallCli = [bool]$cfg.speedtest.autoInstallCli } catch {}
    }
}
elseif ($null -ne $cfg -and $null -ne $cfg.speedTestTarget) {
    # Backward compatibility with legacy "speedTestTarget" key
    if ($null -ne $cfg.speedTestTarget.serverId) {
        $sid = [string]$cfg.speedTestTarget.serverId
        if (-not [string]::IsNullOrWhiteSpace($sid)) { $speedtestServerId = $sid }
    }
    if ($null -ne $cfg.speedTestTarget.summaryAfterSeconds -and [int]$cfg.speedTestTarget.summaryAfterSeconds -gt 0) {
        $speedtestInterval = [int]$cfg.speedTestTarget.summaryAfterSeconds
    }
    elseif ($null -ne $cfg.speedTestTarget.intervalSecond -and [int]$cfg.speedTestTarget.intervalSecond -gt 0) {
        # Backward compatibility with old key name
        $speedtestInterval = [int]$cfg.speedTestTarget.intervalSecond
    }
    if ($null -ne $cfg.speedTestTarget.runOnStart) {
        try { $speedtestRunOnStart = [bool]$cfg.speedTestTarget.runOnStart } catch {}
    }
    if ($null -ne $cfg.speedTestTarget.cooldownAfter429Second -and [int]$cfg.speedTestTarget.cooldownAfter429Second -gt 0) {
        $speedtestRateLimitCooldownSeconds = [int]$cfg.speedTestTarget.cooldownAfter429Second
    }
}
$cfg = $null   # release parsed JSON

$speedtestExePath = $null
if ($doSpeedtest) {
    $speedtestExePath = Ensure-SpeedtestCli -PreferredPath $speedtestCliPath -DownloadUrl $speedtestCliDownloadUrl -AutoInstall $speedtestAutoInstallCli
    if ([string]::IsNullOrWhiteSpace($speedtestExePath)) {
        Write-Colored "> Speedtest disabled because speedtest.exe could not be prepared." Red
        $doSpeedtest = $false
    }
}

$speedtestNextAllowedAt = Get-Date
$speedtestNextRunAt = (Get-Date).AddSeconds($speedtestInterval)

Write-Colored ("Ping test: {0} | Speedtest: {1} | Summary interval: {2}s" -f $doPingTest, $doSpeedtest, $monitorInterval) Cyan
Write-Colored ("Targets: {0}" -f (($targets | ForEach-Object { "{0} ({1})" -f $_.name, $_.targetHost }) -join " - ")) Cyan
if ($doSpeedtest) {
    Write-Colored ("Speedtest interval: {0}s | Run on start: {1} | Rate-limit cooldown: {2}s" -f $speedtestInterval, $speedtestRunOnStart, $speedtestRateLimitCooldownSeconds) Cyan
    $configuredServerIdText = if (-not [string]::IsNullOrWhiteSpace($speedtestServerId)) { $speedtestServerId } else { 'auto' }
    Write-Colored ("Speedtest configured server ID: {0}" -f $configuredServerIdText) Cyan
    Write-Colored ("Speedtest CLI path: {0}" -f $speedtestExePath) Cyan
}

# --- Run speedtest once before the ping loop ---
if ($doSpeedtest -and $speedtestRunOnStart) {
    Write-Host ""
    Write-Host "=== Running Speedtest ==="
    $stResult = Invoke-Speedtest -ServerId $speedtestServerId -SpeedtestExePath $speedtestExePath
    Write-Host ("> Speedtest | DL:{0}Mbps  UL:{1}Mbps" -f $stResult.Download, $stResult.Upload)
    $speedtestNextRunAt = (Get-Date).AddSeconds($speedtestInterval)
    if ($stResult.RateLimited) {
        $speedtestNextAllowedAt = (Get-Date).AddSeconds($speedtestRateLimitCooldownSeconds)
        if ($speedtestNextRunAt -lt $speedtestNextAllowedAt) {
            $speedtestNextRunAt = $speedtestNextAllowedAt
        }
        Write-Colored ("> Speedtest cooldown active until {0}" -f $speedtestNextAllowedAt.ToString("HH:mm:ss")) Yellow
    }
}

# --- Main Loop ---
while ($true) {

    if ($doPingTest) {

        if ($counter -eq 0) {
            Write-Colored "Legends: T:time | J:jitter | L:loss" Cyan
        }

        $timestamp = Get-Date -Format "HH:mm:ss"
        # StringBuilder avoids repeated string allocations per ping cycle
        $sb    = [System.Text.StringBuilder]::new()
        [void]$sb.Append("$timestamp ")

        # Pre-sized List avoids array copy-on-write overhead when adding tasks
        $tasks = [System.Collections.Generic.List[object]]::new($targets.Count)

        foreach ($t in $targets) {
            # Initialise per-target state on first encounter
            if (-not $state.ContainsKey($t.targetHost)) {
                $state[$t.targetHost] = @{
                    sent        = 0
                    recv        = 0
                    lastLatency = $null
                    # Pre-sized Lists avoid reallocation during normal operation
                    latHistory  = [System.Collections.Generic.List[double]]::new($monitorInterval)
                    jitHistory  = [System.Collections.Generic.List[double]]::new($monitorInterval)
                    lossHistory = [System.Collections.Generic.List[double]]::new($monitorInterval)
                }
            }

            $state[$t.targetHost].sent++
            $ping, $task = Start-PingAsync -targetHost $t.targetHost -timeoutMs 1000
            $tasks.Add([PSCustomObject]@{ Target = $t; Ping = $ping; Task = $task })
        }

        [Threading.Tasks.Task]::WaitAll(($tasks | ForEach-Object { $_.Task }))

        foreach ($entry in $tasks) {
            $t     = $entry.Target
            $s     = $state[$t.targetHost]
            $reply = $entry.Task.Result

            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $lat  = $reply.RoundtripTime
                $s.recv++
                $jit  = if ($null -ne $s.lastLatency) { [math]::Abs($lat - $s.lastLatency) } else { 0 }
                $s.lastLatency = $lat
                $loss = [math]::Round((($s.sent - $s.recv) / $s.sent) * 100, 2)
                $s.latHistory.Add($lat)
                $s.jitHistory.Add($jit)
                $s.lossHistory.Add($loss)
                [void]$sb.Append(("[{0}|T:{1}ms|J:{2}ms|L:{3}%]" -f $t.name, $lat, $jit, $loss))
            } else {
                $loss = [math]::Round((($s.sent - $s.recv) / $s.sent) * 100, 2)
                $s.latHistory.Add(999)
                $s.jitHistory.Add(0)
                $s.lossHistory.Add($loss)
                [void]$sb.Append(("[{0}|timeout|L:{1}%]" -f $t.name, $loss))
            }

            # Dispose Ping to free the underlying socket immediately
            $entry.Ping.Dispose()

            # Cap history at $monitorInterval entries using RemoveAt (no new array allocation)
            if ($s.latHistory.Count  -gt $monitorInterval) { $s.latHistory.RemoveAt(0)  }
            if ($s.jitHistory.Count  -gt $monitorInterval) { $s.jitHistory.RemoveAt(0)  }
            if ($s.lossHistory.Count -gt $monitorInterval) { $s.lossHistory.RemoveAt(0) }
        }

        Write-Host $sb.ToString()
    }

    # --- Every N seconds: print per-target summaries and run speedtest ---
    $counter++
    if ($counter -ge $monitorInterval) {

        if ($doPingTest) {
            Write-Host ""
            Write-Host "=== Ping Summary (per gateway) ==="
            foreach ($t in $targets) {
                $s = $state[$t.targetHost]
                $avgLatency = if ($s.latHistory.Count  -gt 0) { [math]::Round(($s.latHistory  | Measure-Object -Average).Average, 2) } else { 0 }
                $avgJitter  = if ($s.jitHistory.Count  -gt 0) { [math]::Round(($s.jitHistory  | Measure-Object -Average).Average, 2) } else { 0 }
                $finalLoss  = if ($s.lossHistory.Count -gt 0) { $s.lossHistory[$s.lossHistory.Count - 1] } else { 0 }
                Write-TargetLine $t.name $t.targetHost $avgLatency $avgJitter $finalLoss
            }

            Write-Host ""
            Write-Host "=== Network Stability (per gateway) ==="
            foreach ($t in $targets) {
                $s = $state[$t.targetHost]
                $avgLatency = if ($s.latHistory.Count  -gt 0) { [math]::Round(($s.latHistory  | Measure-Object -Average).Average, 2) } else { 0 }
                $avgJitter  = if ($s.jitHistory.Count  -gt 0) { [math]::Round(($s.jitHistory  | Measure-Object -Average).Average, 2) } else { 0 }
                $finalLoss  = if ($s.lossHistory.Count -gt 0) { $s.lossHistory[$s.lossHistory.Count - 1] } else { 0 }
                Write-TargetLine $t.name $t.targetHost $avgLatency $avgJitter $finalLoss
            }

            Write-Host ""
            Write-Host ""
        }

        $counter = 0
    }

    # Speedtest scheduler (independent from ping summary interval)
    if ($doSpeedtest) {
        $now = Get-Date
        if ($now -ge $speedtestNextRunAt) {
            if ($now -lt $speedtestNextAllowedAt) {
                $remaining = [math]::Max(1, [int](($speedtestNextAllowedAt - $now).TotalSeconds))
                Write-Colored ("> Speedtest skipped: cooldown active ({0}s remaining)" -f $remaining) Yellow
                $speedtestNextRunAt = $speedtestNextAllowedAt
            }
            else {
                Write-Host ""
                Write-Host "=== Running Speedtest ==="
                $stResult = Invoke-Speedtest -ServerId $speedtestServerId -SpeedtestExePath $speedtestExePath
                Write-Host ("> Speedtest | DL:{0}Mbps  UL:{1}Mbps" -f $stResult.Download, $stResult.Upload)

                $speedtestNextRunAt = (Get-Date).AddSeconds($speedtestInterval)
                if ($stResult.RateLimited) {
                    $speedtestNextAllowedAt = (Get-Date).AddSeconds($speedtestRateLimitCooldownSeconds)
                    if ($speedtestNextRunAt -lt $speedtestNextAllowedAt) {
                        $speedtestNextRunAt = $speedtestNextAllowedAt
                    }
                    Write-Colored ("> Speedtest cooldown active until {0}" -f $speedtestNextAllowedAt.ToString("HH:mm:ss")) Yellow
                }
            }
        }
    }

    Start-Sleep -Seconds 1
}
