@echo off
setlocal

title Network Monitor
set "SCRIPT_DIR=%~dp0"
set "CONFIG_PATH=%SCRIPT_DIR%config.json"
set "TEMP_PS1=%TEMP%\network_monitor.generated.ps1"
set "NM_CONFIG_PATH=%CONFIG_PATH%"

powershell -NoProfile -ExecutionPolicy Bypass -Command "$self = Get-Content -Raw -Path '%~f0'; $m = [regex]::Match($self, '(?s):__PWSH_BEGIN__\r?\n(.*?)\r?\n:__PWSH_END__'); if (-not $m.Success) { Write-Host 'Embedded PowerShell payload not found in launcher.' -ForegroundColor Red; exit 1 }; Set-Content -Path '%TEMP_PS1%' -Value $m.Groups[1].Value -Encoding UTF8"

if errorlevel 1 (
  echo Failed to generate temporary PowerShell script.
  exit /b 1
)

if /I "%NM_NOEXIT%"=="0" (
    powershell -ExecutionPolicy Bypass -File "%TEMP_PS1%"
) else (
    powershell -NoExit -ExecutionPolicy Bypass -File "%TEMP_PS1%"
)
exit /b %ERRORLEVEL%

:__PWSH_BEGIN__
# ============================
# Network Monitor (Async Multi-Target, Per-Target Summaries)
# - Targets are primarily configured in config.json pingTest.pingTargets
# ============================

# --- Configuration ---
$scriptDir      = Split-Path -Parent $MyInvocation.MyCommand.Definition
$configPath     = if (-not [string]::IsNullOrWhiteSpace($env:NM_CONFIG_PATH)) { $env:NM_CONFIG_PATH } else { Join-Path $scriptDir 'config.json' }
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
    Write-Host ("{0} ({1}) | Latency:{2}ms " -f $name, $address, $avgLatency) -NoNewline
    Write-Host $latTag.text  -ForegroundColor $latTag.color  -NoNewline
    Write-Host ("  Jitter:{0}ms " -f $avgJitter) -NoNewline
    Write-Host $jitTag.text  -ForegroundColor $jitTag.color  -NoNewline
    Write-Host ("  Loss:{0}% " -f $finalLoss) -NoNewline
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

# Loads targets from config.json and applies enabled-target rules.
# Returns a result object with Targets array and parsed Config for reuse (avoids double file read).
function Load-Config {
    param($path)

    if (-not (Test-Path $path)) {
        Write-Colored ("Config not found - using default target {0}" -f $defaultPrimary.targetHost) Yellow
        return [PSCustomObject]@{ Targets = @($defaultPrimary); Config = $null }
    }

    try {
        $json = Get-Content $path -Raw | ConvertFrom-Json

        $list = [System.Collections.Generic.List[object]]::new()
        $hasConfiguredTargets = $false
        $pingTargets = $null
        if ($null -ne $json.pingTest -and $null -ne $json.pingTest.pingTargets) {
            $pingTargets = $json.pingTest.pingTargets
        }
        elseif ($null -ne $json.pingTargets) {
            # Backward compatibility with legacy top-level key
            $pingTargets = $json.pingTargets
        }

        if ($null -ne $pingTargets) {
            $hasConfiguredTargets = $true
            foreach ($t in $pingTargets) {
                if (-not $t.host) { continue }
                $name = if ($t.name) { $t.name } else { $t.host }
                $targetEnabled = $true
                if ($null -ne $t.enabled) {
                    try { $targetEnabled = [bool]$t.enabled } catch {}
                }
                if (-not $targetEnabled) { continue }
                $list.Add([PSCustomObject]@{
                    name = $name
                    targetHost = $t.host
                    timeoutMs = $t.timeoutMs
                    avgLatencyThresholdMs = $t.avgLatencyThresholdMs
                    avgJitterThresholdMs = $t.avgJitterThresholdMs
                })
            }
        }

        if ($list.Count -eq 0) {
            if ($hasConfiguredTargets) {
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

# Computes a percentile (with linear interpolation) from a pre-sorted numeric array.
function Get-Percentile {
    param(
        [double[]]$SortedValues,
        [double]$Percentile
    )

    if ($null -eq $SortedValues -or $SortedValues.Count -eq 0) {
        return 0.0
    }

    if ($SortedValues.Count -eq 1) {
        return [math]::Round($SortedValues[0], 2)
    }

    $rank  = ($Percentile / 100.0) * ($SortedValues.Count - 1)
    $lower = [int][math]::Floor($rank)
    $upper = [int][math]::Ceiling($rank)

    if ($lower -eq $upper) {
        return [math]::Round($SortedValues[$lower], 2)
    }

    $weight = $rank - $lower
    return [math]::Round(($SortedValues[$lower] + (($SortedValues[$upper] - $SortedValues[$lower]) * $weight)), 2)
}

# Aggregates one target's ring-buffer samples into summary metrics.
function Get-TargetWindowStats {
    param($TargetState)

    $latencies = [System.Collections.Generic.List[double]]::new()
    $jitters   = [System.Collections.Generic.List[double]]::new()
    $timeoutCount = 0

    for ($i = 0; $i -lt $TargetState.sampleCount; $i++) {
        if ($TargetState.successRing[$i]) {
            $lat = [double]$TargetState.latRing[$i]
            if (-not [double]::IsNaN($lat)) {
                $latencies.Add($lat)
            }

            $jit = [double]$TargetState.jitRing[$i]
            if (-not [double]::IsNaN($jit)) {
                $jitters.Add($jit)
            }
        }
        else {
            $timeoutCount++
        }
    }

    $avgLatency = 0.0
    if ($latencies.Count -gt 0) {
        $latSum = 0.0
        foreach ($value in $latencies) { $latSum += $value }
        $avgLatency = [math]::Round(($latSum / $latencies.Count), 2)
    }

    $avgJitter = 0.0
    if ($jitters.Count -gt 0) {
        $jitSum = 0.0
        foreach ($value in $jitters) { $jitSum += $value }
        $avgJitter = [math]::Round(($jitSum / $jitters.Count), 2)
    }

    $p50 = 0.0
    $p95 = 0.0
    $p99 = 0.0
    if ($latencies.Count -gt 0) {
        $sorted = $latencies.ToArray()
        [Array]::Sort($sorted)
        $p50 = Get-Percentile -SortedValues $sorted -Percentile 50
        $p95 = Get-Percentile -SortedValues $sorted -Percentile 95
        $p99 = Get-Percentile -SortedValues $sorted -Percentile 99
    }

    $sentInWindow = [int]$TargetState.sampleCount
    $loss = if ($sentInWindow -gt 0) { [math]::Round((($timeoutCount / $sentInWindow) * 100), 2) } else { 0.0 }

    return [PSCustomObject]@{
        AvgLatency     = $avgLatency
        AvgJitter      = $avgJitter
        EwmaJitter     = [math]::Round([double]$TargetState.ewmaJitter, 2)
        P50Latency     = $p50
        P95Latency     = $p95
        P99Latency     = $p99
        FinalLoss      = $loss
        TimeoutCount   = $timeoutCount
        SuccessCount   = $latencies.Count
        SentInWindow   = $sentInWindow
    }
}

# Lightweight DNS reachability checks with timing.
function Invoke-DnsChecks {
    param([string[]]$Hosts)

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Hosts) { return $results }

    foreach ($dnsHost in $Hosts) {
        if ([string]::IsNullOrWhiteSpace($dnsHost)) { continue }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $addresses = [System.Net.Dns]::GetHostAddresses($dnsHost)
            $sw.Stop()
            $results.Add([PSCustomObject]@{
                Type   = 'DNS'
                Target = $dnsHost
                Ok     = ($addresses.Count -gt 0)
                Ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Detail = if ($addresses.Count -gt 0) { ($addresses | Select-Object -First 2 | ForEach-Object { $_.ToString() }) -join ', ' } else { 'No addresses returned' }
            })
        }
        catch {
            $sw.Stop()
            $results.Add([PSCustomObject]@{
                Type   = 'DNS'
                Target = $dnsHost
                Ok     = $false
                Ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Detail = $_.Exception.Message
            })
        }
    }

    return $results
}

# TCP connect checks to validate application path independently from ICMP.
function Invoke-TcpChecks {
    param(
        [object[]]$Targets,
        [int]$TimeoutMs = 2000
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Targets) { return $results }

    foreach ($target in $Targets) {
        if ($null -eq $target -or [string]::IsNullOrWhiteSpace([string]$target.host)) { continue }

        $tcpHost = [string]$target.host
        $port = if ($null -ne $target.port -and [int]$target.port -gt 0) { [int]$target.port } else { 443 }

        $client = [System.Net.Sockets.TcpClient]::new()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $connectTask = $client.ConnectAsync($tcpHost, $port)
            if (-not $connectTask.Wait($TimeoutMs)) {
                throw "Timed out after $TimeoutMs ms"
            }

            $sw.Stop()
            $results.Add([PSCustomObject]@{
                Type   = 'TCP'
                Target = "$tcpHost`:$port"
                Ok     = $true
                Ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Detail = 'Connected'
            })
        }
        catch {
            $sw.Stop()
            $results.Add([PSCustomObject]@{
                Type   = 'TCP'
                Target = "$tcpHost`:$port"
                Ok     = $false
                Ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Detail = $_.Exception.Message
            })
        }
        finally {
            $client.Dispose()
        }
    }

    return $results
}

# HTTP checks to validate endpoint responsiveness from user-space.
function Invoke-HttpChecks {
    param(
        [string[]]$Urls,
        [int]$TimeoutSeconds = 5
    )

    $results = [System.Collections.Generic.List[object]]::new()
    if ($null -eq $Urls) { return $results }

    foreach ($url in $Urls) {
        if ([string]::IsNullOrWhiteSpace($url)) { continue }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $response = Invoke-WebRequest -Uri $url -Method Get -TimeoutSec $TimeoutSeconds -UseBasicParsing
            $sw.Stop()
            $results.Add([PSCustomObject]@{
                Type   = 'HTTP'
                Target = $url
                Ok     = ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
                Ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Detail = "Status $($response.StatusCode)"
            })
        }
        catch {
            $sw.Stop()
            $results.Add([PSCustomObject]@{
                Type   = 'HTTP'
                Target = $url
                Ok     = $false
                Ms     = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
                Detail = $_.Exception.Message
            })
        }
    }

    return $results
}

# Runs all non-ICMP service checks and prints compact one-line results.
function Invoke-ServiceHealthChecks {
    param(
        [string[]]$DnsHosts,
        [object[]]$TcpTargets,
        [string[]]$HttpUrls,
        [int]$TcpTimeoutMs,
        [int]$HttpTimeoutSeconds
    )

    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($item in (Invoke-DnsChecks -Hosts $DnsHosts)) { $all.Add($item) }
    foreach ($item in (Invoke-TcpChecks -Targets $TcpTargets -TimeoutMs $TcpTimeoutMs)) { $all.Add($item) }
    foreach ($item in (Invoke-HttpChecks -Urls $HttpUrls -TimeoutSeconds $HttpTimeoutSeconds)) { $all.Add($item) }

    if ($all.Count -eq 0) {
        Write-Colored "Service checks are enabled, but no DNS/TCP/HTTP targets are configured." Yellow
        return
    }

    Write-Host "=== Service Reachability Checks ==="
    foreach ($r in $all) {
        $status = if ($r.Ok) { 'OK' } else { 'FAIL' }
        $color  = if ($r.Ok) { 'Green' } else { 'Red' }
        Write-Host ("[{0}] {1} | {2}ms | {3} | {4}" -f $r.Type, $r.Target, $r.Ms, $status, $r.Detail) -ForegroundColor $color
    }
}

# Captures additional diagnostics once when an incident begins.
function Invoke-IncidentDiagnostics {
    param(
        $Target,
        $Stats,
        [string[]]$DnsHosts,
        [object[]]$TcpTargets,
        [string[]]$HttpUrls,
        [int]$TcpTimeoutMs,
        [int]$HttpTimeoutSeconds
    )

    Write-Colored ("> Incident diagnostics started for {0} ({1})" -f $Target.name, $Target.targetHost) Yellow
    Write-Host ("> Trigger snapshot | Loss:{0}% AvgLatency:{1}ms AvgJitter:{2}ms P95:{3}ms" -f $Stats.FinalLoss, $Stats.AvgLatency, $Stats.AvgJitter, $Stats.P95Latency)

    try {
        $trace = tracert -d -h 12 $Target.targetHost 2>&1
        if ($trace) {
            Write-Host "> Traceroute (first 12 hops):"
            $trace | ForEach-Object { Write-Host $_ }
        }
    }
    catch {
        Write-Colored ("> Traceroute failed: {0}" -f $_.Exception.Message) Red
    }

    Invoke-ServiceHealthChecks -DnsHosts $DnsHosts -TcpTargets $TcpTargets -HttpUrls $HttpUrls -TcpTimeoutMs $TcpTimeoutMs -HttpTimeoutSeconds $HttpTimeoutSeconds
}

# --- System Requirements Check ---
function Test-SystemRequirements {
    $errors   = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    # 1. Windows-only (tracert, ICMP APIs)
    $platform = [System.Environment]::OSVersion.Platform
    if ($platform -ne [System.PlatformID]::Win32NT) {
        $errors.Add("Windows is required (detected: $platform). Tracert and ICMP diagnostics are Windows-only.")
    }

    # 2. PowerShell version: 3.0+ mandatory, 5.0+ for speedtest CLI auto-install
    $psVer = $PSVersionTable.PSVersion
    if ($psVer.Major -lt 3) {
        $errors.Add("PowerShell 3.0 or higher is required (detected: $($psVer.ToString())). Install WMF 3.0+ from microsoft.com.")
    } elseif ($psVer.Major -lt 5) {
        $warnings.Add("PowerShell 5.0+ is recommended for speedtest CLI auto-install (Expand-Archive). Detected: $($psVer.ToString()). Auto-install will be unavailable.")
    }

    # 3. .NET CLR 4.0+ ??? required for Ping.SendPingAsync, Task.WaitAll, TcpClient.ConnectAsync
    $clr = [System.Environment]::Version
    if ($clr.Major -lt 4) {
        $errors.Add(".NET Framework 4.0 or higher is required for async ping and TCP (detected CLR: $($clr.ToString())). Install .NET Framework 4.5+ from microsoft.com.")
    }

    # Print warnings (non-blocking)
    foreach ($w in $warnings) {
        Write-Host "[REQUIREMENT WARNING] $w" -ForegroundColor Yellow
    }
    if ($warnings.Count -gt 0) { Write-Host "" }

    # Print errors and exit if any
    if ($errors.Count -gt 0) {
        Write-Host "=== System Requirements Check FAILED ===" -ForegroundColor Red
        foreach ($e in $errors) {
            Write-Host "[REQUIREMENT ERROR] $e" -ForegroundColor Red
        }
        Write-Host ""
        Write-Host "This script cannot run on the current system. Please resolve the issues above and try again." -ForegroundColor Red
        exit 1
    }
}

Test-SystemRequirements

# Enforce TLS 1.2 globally for all outbound HTTPS (Invoke-WebRequest, speedtest download, etc.)
# PowerShell 5.1 defaults to TLS 1.0; most modern servers require TLS 1.2+.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# Trust all certificates globally using a proper .NET delegate (PS 5.1 compatible).
# Required when SSL inspection (corporate proxy, antivirus) presents a substitute certificate.
# Scriptblocks cannot be cast to RemoteCertificateValidationCallback; Add-Type is needed.
if (-not ([System.Management.Automation.PSTypeName]'NetworkMonitor.TrustAllCerts').Type) {
    Add-Type @"
using System.Net;
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
namespace NetworkMonitor {
    public class TrustAllCerts {
        public static RemoteCertificateValidationCallback Callback =
            delegate(object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; };
    }
}
"@
}
[Net.ServicePointManager]::ServerCertificateValidationCallback = [NetworkMonitor.TrustAllCerts]::Callback

# --- Bootstrap: load config once, deduplicate targets ---
$cfgResult = Load-Config -path $configPath
$targets   = $cfgResult.Targets
$cfg       = $cfgResult.Config
$cfgResult = $null   # release wrapper

if ($null -eq $targets) {
    $targets = @()
}

if ($targets.Count -gt 0) {
    # Deduplicate by address using a HashSet (O(1) lookup, no extra hashtable overhead)
    $seen    = [System.Collections.Generic.HashSet[string]]::new()
    $targets = @($targets | Where-Object { $seen.Add($_.targetHost) })
    $seen    = $null   # free immediately
}

# Read test settings from the already-parsed config (no second file read)
$doPingTest           = $true
$doSpeedtest          = $false
$monitorInterval      = 60
$pingIntervalMs       = 1000
$pingTimeoutMs        = 1000
$delayAfterSummaryMs  = 2000
$speedtestServerId = $null
$speedtestRunOnStart = $false
$speedtestRateLimitCooldownSeconds = 1800
$speedtestCliPath = $null
$speedtestCliDownloadUrl = "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
$speedtestAutoInstallCli = $true
$jitterEwmaAlpha = 0.2
$healthChecksEnabled = $false
$healthDnsHosts = @('www.google.com', 'www.cloudflare.com')
$healthTcpTargets = @(
    [PSCustomObject]@{ host = '1.1.1.1'; port = 443 },
    [PSCustomObject]@{ host = '8.8.8.8'; port = 443 }
)
$healthDnsHostsTotalCount = $healthDnsHosts.Count
$healthDnsHostsEnabledCount = $healthDnsHosts.Count
$healthTcpTargetsTotalCount = $healthTcpTargets.Count
$healthTcpTargetsEnabledCount = $healthTcpTargets.Count
$healthHttpUrls = @('https://www.msftconnecttest.com/connecttest.txt')
$healthHttpUrlsTotalCount = $healthHttpUrls.Count
$healthHttpUrlsEnabledCount = $healthHttpUrls.Count
$healthTcpTimeoutMs = 2000
$healthHttpTimeoutSeconds = 5
$incidentDiagnosticsEnabled = $true
$incidentLossThresholdPercent = 2.0
$incidentAvgLatencyThresholdMs = 120.0
$incidentAvgJitterThresholdMs = 30.0
$incidentConsecutiveBreachSummaries = 2
$incidentCooldownSeconds = 600
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
    if ($null -ne $cfg.pingTest.summary) {
        if ($null -ne $cfg.pingTest.summary.summaryAfterPings -and [int]$cfg.pingTest.summary.summaryAfterPings -gt 0) {
            $monitorInterval = [int]$cfg.pingTest.summary.summaryAfterPings
        }
        if ($null -ne $cfg.pingTest.summary.delayAfterSummarySeconds -and [int]$cfg.pingTest.summary.delayAfterSummarySeconds -ge 0) {
            $delayAfterSummaryMs = [int]$cfg.pingTest.summary.delayAfterSummarySeconds * 1000
        }
    }
    # Backward compatibility: flat keys
    if ($null -ne $cfg.pingTest.summaryAfterPings -and [int]$cfg.pingTest.summaryAfterPings -gt 0) {
        $monitorInterval = [int]$cfg.pingTest.summaryAfterPings
    }
    elseif ($null -ne $cfg.pingTest.summaryAfterSeconds -and [int]$cfg.pingTest.summaryAfterSeconds -gt 0) {
        # Backward compatibility with old key name
        $monitorInterval = [int]$cfg.pingTest.summaryAfterSeconds
    }
    elseif ($null -ne $cfg.pingTest.monitorIntervalSecond -and [int]$cfg.pingTest.monitorIntervalSecond -gt 0) {
        # Backward compatibility with old key name
        $monitorInterval = [int]$cfg.pingTest.monitorIntervalSecond
    }
    if ($null -ne $cfg.pingTest.pingIntervalMilSeconds -and [int]$cfg.pingTest.pingIntervalMilSeconds -ge 0) {
        $pingIntervalMs = [int]$cfg.pingTest.pingIntervalMilSeconds
    }
    if ($null -ne $cfg.pingTest.timeoutMs -and [int]$cfg.pingTest.timeoutMs -gt 0) {
        $pingTimeoutMs = [int]$cfg.pingTest.timeoutMs
    }
    elseif ($null -ne $cfg.pingTest.pingTimeoutMilSeconds -and [int]$cfg.pingTest.pingTimeoutMilSeconds -gt 0) {
        # Backward compatibility with alternate key spelling
        $pingTimeoutMs = [int]$cfg.pingTest.pingTimeoutMilSeconds
    }
    if ($null -ne $cfg.pingTest.delayAfterSummarySeconds -and [int]$cfg.pingTest.delayAfterSummarySeconds -ge 0) {
        $delayAfterSummaryMs = [int]$cfg.pingTest.delayAfterSummarySeconds * 1000
    }
}

# Current schema: top-level summary
if ($null -ne $cfg -and $null -ne $cfg.summary) {
    if ($null -ne $cfg.summary.summaryAfterPings -and [int]$cfg.summary.summaryAfterPings -gt 0) {
        $monitorInterval = [int]$cfg.summary.summaryAfterPings
    }
    if ($null -ne $cfg.summary.delayAfterSummarySeconds -and [int]$cfg.summary.delayAfterSummarySeconds -ge 0) {
        $delayAfterSummaryMs = [int]$cfg.summary.delayAfterSummarySeconds * 1000
    }
}

if ($null -ne $cfg -and $null -ne $cfg.speedtest) {
    if ($null -ne $cfg.speedtest.serverId) {
        $sid = [string]$cfg.speedtest.serverId
        if (-not [string]::IsNullOrWhiteSpace($sid)) { $speedtestServerId = $sid }
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
    if ($null -ne $cfg.speedTestTarget.runOnStart) {
        try { $speedtestRunOnStart = [bool]$cfg.speedTestTarget.runOnStart } catch {}
    }
    if ($null -ne $cfg.speedTestTarget.cooldownAfter429Second -and [int]$cfg.speedTestTarget.cooldownAfter429Second -gt 0) {
        $speedtestRateLimitCooldownSeconds = [int]$cfg.speedTestTarget.cooldownAfter429Second
    }
}

 $healthChecksCfg = $null
if ($null -ne $cfg -and $null -ne $cfg.pingTest -and $null -ne $cfg.pingTest.healthChecks) {
    $healthChecksCfg = $cfg.pingTest.healthChecks
}
elseif ($null -ne $cfg -and $null -ne $cfg.healthChecks) {
    # Backward compatibility with legacy top-level key
    $healthChecksCfg = $cfg.healthChecks
}

if ($null -ne $healthChecksCfg) {
    if ($null -ne $healthChecksCfg.enabled) {
        try { $healthChecksEnabled = [bool]$healthChecksCfg.enabled } catch {}
    }
    if ($null -ne $healthChecksCfg.dnsHosts) {
        $parsedDnsHosts = [System.Collections.Generic.List[string]]::new()
        $healthDnsHostsTotalCount = 0
        foreach ($dh in $healthChecksCfg.dnsHosts) {
            $healthDnsHostsTotalCount++
            $dnsHost = $null
            $dnsEnabled = $true

            if ($dh -is [string]) {
                $dnsHost = [string]$dh
            }
            else {
                if ($null -eq $dh) { continue }
                $dnsHost = [string]$dh.host
                if ($null -ne $dh.enabled) {
                    try { $dnsEnabled = [bool]$dh.enabled } catch {}
                }
            }

            if ([string]::IsNullOrWhiteSpace($dnsHost)) { continue }
            if ($dnsEnabled) { $parsedDnsHosts.Add($dnsHost) }
        }
        $healthDnsHosts = $parsedDnsHosts.ToArray()
        $healthDnsHostsEnabledCount = $healthDnsHosts.Count
    }
    if ($null -ne $healthChecksCfg.tcpTargets) {
        $parsedTcpTargets = [System.Collections.Generic.List[object]]::new()
        $healthTcpTargetsTotalCount = 0
        foreach ($tt in $healthChecksCfg.tcpTargets) {
            $healthTcpTargetsTotalCount++
            if ($null -eq $tt -or [string]::IsNullOrWhiteSpace([string]$tt.host)) { continue }
            $tcpEnabled = $true
            if ($null -ne $tt.enabled) {
                try { $tcpEnabled = [bool]$tt.enabled } catch {}
            }
            if (-not $tcpEnabled) { continue }
            $port = if ($null -ne $tt.port -and [int]$tt.port -gt 0) { [int]$tt.port } else { 443 }
            $parsedTcpTargets.Add([PSCustomObject]@{ host = [string]$tt.host; port = $port })
        }
        $healthTcpTargets = $parsedTcpTargets.ToArray()
        $healthTcpTargetsEnabledCount = $healthTcpTargets.Count
    }
    if ($null -ne $healthChecksCfg.httpUrls) {
        $parsedHttpUrls = [System.Collections.Generic.List[string]]::new()
        $healthHttpUrlsTotalCount = 0
        foreach ($hu in $healthChecksCfg.httpUrls) {
            $healthHttpUrlsTotalCount++
            $httpUrl = $null
            $httpEnabled = $true

            if ($hu -is [string]) {
                $httpUrl = [string]$hu
            }
            else {
                if ($null -eq $hu) { continue }
                $httpUrl = [string]$hu.url
                if ($null -ne $hu.enabled) {
                    try { $httpEnabled = [bool]$hu.enabled } catch {}
                }
            }

            if ([string]::IsNullOrWhiteSpace($httpUrl)) { continue }
            if ($httpEnabled) { $parsedHttpUrls.Add($httpUrl) }
        }
        $healthHttpUrls = $parsedHttpUrls.ToArray()
        $healthHttpUrlsEnabledCount = $healthHttpUrls.Count
    }
    if ($null -ne $healthChecksCfg.tcpTimeoutMs -and [int]$healthChecksCfg.tcpTimeoutMs -gt 0) {
        $healthTcpTimeoutMs = [int]$healthChecksCfg.tcpTimeoutMs
    }
    if ($null -ne $healthChecksCfg.httpTimeoutSeconds -and [int]$healthChecksCfg.httpTimeoutSeconds -gt 0) {
        $healthHttpTimeoutSeconds = [int]$healthChecksCfg.httpTimeoutSeconds
    }
}

if ($null -ne $cfg -and $null -ne $cfg.incident) {
    if ($null -ne $cfg.incident.enabledDiagnostics) {
        try { $incidentDiagnosticsEnabled = [bool]$cfg.incident.enabledDiagnostics } catch {}
    }
    elseif ($null -ne $cfg.incident.diagnosticsEnabled) {
        try { $incidentDiagnosticsEnabled = [bool]$cfg.incident.diagnosticsEnabled } catch {}
    }
    if ($null -ne $cfg.incident.lossThresholdPercent -and [double]$cfg.incident.lossThresholdPercent -ge 0) {
        $incidentLossThresholdPercent = [double]$cfg.incident.lossThresholdPercent
    }
    if ($null -ne $cfg.incident.avgLatencyThresholdMs -and [double]$cfg.incident.avgLatencyThresholdMs -ge 0) {
        $incidentAvgLatencyThresholdMs = [double]$cfg.incident.avgLatencyThresholdMs
    }
    if ($null -ne $cfg.incident.avgJitterThresholdMs -and [double]$cfg.incident.avgJitterThresholdMs -ge 0) {
        $incidentAvgJitterThresholdMs = [double]$cfg.incident.avgJitterThresholdMs
    }
    if ($null -ne $cfg.incident.consecutiveBreachSummaries -and [int]$cfg.incident.consecutiveBreachSummaries -gt 0) {
        $incidentConsecutiveBreachSummaries = [int]$cfg.incident.consecutiveBreachSummaries
    }
    if ($null -ne $cfg.incident.cooldownSeconds -and [int]$cfg.incident.cooldownSeconds -gt 0) {
        $incidentCooldownSeconds = [int]$cfg.incident.cooldownSeconds
    }
}

if ($null -ne $cfg -and $null -ne $cfg.summary) {
    if ($null -ne $cfg.summary.jitterEwmaAlpha -and [double]$cfg.summary.jitterEwmaAlpha -gt 0 -and [double]$cfg.summary.jitterEwmaAlpha -le 1) {
        $jitterEwmaAlpha = [double]$cfg.summary.jitterEwmaAlpha
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

Write-Colored ("Ping test: {0} | Speedtest: {1} | Summary after: {2} pings | Ping interval: {3}ms | Ping timeout: {4}ms | Delay after summary: {5}ms" -f $doPingTest, $doSpeedtest, $monitorInterval, $pingIntervalMs, $pingTimeoutMs, $delayAfterSummaryMs) Cyan
$targetSummaryText = if ($targets.Count -gt 0) { (($targets | ForEach-Object { "{0} ({1})" -f $_.name, $_.targetHost }) -join " - ") } else { 'none' }
Write-Colored ("Targets: {0}" -f $targetSummaryText) Cyan
Write-Colored ("Incident diagnostics: {0} | Loss>={1}% Latency>={2}ms Jitter>={3}ms | Consecutive summaries: {4} | Cooldown: {5}s" -f $incidentDiagnosticsEnabled, $incidentLossThresholdPercent, $incidentAvgLatencyThresholdMs, $incidentAvgJitterThresholdMs, $incidentConsecutiveBreachSummaries, $incidentCooldownSeconds) Cyan
Write-Colored ("Service checks: {0} | DNS:{1} TCP:{2} HTTP:{3}" -f $healthChecksEnabled, $healthDnsHosts.Count, $healthTcpTargets.Count, $healthHttpUrls.Count) Cyan
if ($doSpeedtest) {
    Write-Colored ("Speedtest trigger: with each displayed summary | Run on start: {0} | Rate-limit cooldown: {1}s" -f $speedtestRunOnStart, $speedtestRateLimitCooldownSeconds) Cyan
    $configuredServerIdText = if (-not [string]::IsNullOrWhiteSpace($speedtestServerId)) { $speedtestServerId } else { 'auto' }
    Write-Colored ("Speedtest configured server ID: {0}" -f $configuredServerIdText) Cyan
    Write-Colored ("Speedtest CLI path: {0}" -f $speedtestExePath) Cyan
}

# Startup confirmation before beginning any tests.
$testsToRun = [System.Collections.Generic.List[string]]::new()
$runWarnings = [System.Collections.Generic.List[string]]::new()
$enabledPingTargetsCount = $targets.Count
$enabledHealthTargetsCount = $healthDnsHosts.Count + $healthTcpTargets.Count + $healthHttpUrls.Count

$effectivePingTest = ($doPingTest -and $enabledPingTargetsCount -gt 0)
$effectiveSpeedtest = ($doSpeedtest -and $effectivePingTest)
$effectiveHealthChecks = ($healthChecksEnabled -and $effectivePingTest -and $enabledHealthTargetsCount -gt 0)

if ($doPingTest -and $enabledPingTargetsCount -eq 0) {
    $runWarnings.Add("pingTest is enabled, but no pingTargets are enabled.")
}
if ($healthChecksEnabled -and $enabledHealthTargetsCount -eq 0) {
    $runWarnings.Add("healthChecks is enabled, but no DNS/TCP/HTTP health targets are enabled.")
}
if ($healthChecksEnabled -and $healthDnsHostsTotalCount -gt 0 -and $healthDnsHostsEnabledCount -eq 0) {
    $runWarnings.Add("healthChecks dnsHosts are configured, but all dnsHosts are disabled.")
}
if ($healthChecksEnabled -and $healthTcpTargetsTotalCount -gt 0 -and $healthTcpTargetsEnabledCount -eq 0) {
    $runWarnings.Add("healthChecks tcpTargets are configured, but all tcpTargets are disabled.")
}
if ($healthChecksEnabled -and $healthHttpUrlsTotalCount -gt 0 -and $healthHttpUrlsEnabledCount -eq 0) {
    $runWarnings.Add("healthChecks httpUrls are configured, but all httpUrls are disabled.")
}

if ($effectivePingTest) { $testsToRun.Add('pingTest') }
if ($effectiveSpeedtest) { $testsToRun.Add('speedtest') }
if ($effectiveHealthChecks) { $testsToRun.Add('healthChecks') }

Write-Host ""
Write-Host "=== Planned Run ===" -ForegroundColor Cyan
Write-Host "Ping targets to test:" -ForegroundColor Cyan
if ($targets.Count -gt 0) {
    foreach ($t in $targets) {
        $targetTimeoutText = if ($null -ne $t.timeoutMs -and [int]$t.timeoutMs -gt 0) { [string]([int]$t.timeoutMs) } else { [string]$pingTimeoutMs }
        $latThresholdText = if ($null -ne $t.avgLatencyThresholdMs) { [string]$t.avgLatencyThresholdMs } else { [string]$incidentAvgLatencyThresholdMs }
        $jitThresholdText = if ($null -ne $t.avgJitterThresholdMs) { [string]$t.avgJitterThresholdMs } else { [string]$incidentAvgJitterThresholdMs }
        Write-Host (" - {0} ({1}) | Timeout:{2}ms | Thresholds: Latency>={3}ms, Jitter>={4}ms" -f $t.name, $t.targetHost, $targetTimeoutText, $latThresholdText, $jitThresholdText)
    }
}
else {
    Write-Host " - none"
}

if ($runWarnings.Count -gt 0) {
    Write-Colored "Warnings:" Yellow
    foreach ($warn in $runWarnings) {
        Write-Colored (" - {0}" -f $warn) Yellow
    }
}

if ($testsToRun.Count -gt 0) {
    Write-Host ("Tests to run: {0}" -f ($testsToRun -join ', ')) -ForegroundColor Cyan
}
else {
    Write-Colored "No runnable tests for current config. Exiting." Yellow
    exit 0
}

$doPingTest = $effectivePingTest
$doSpeedtest = $effectiveSpeedtest
$healthChecksEnabled = $effectiveHealthChecks

$userConsent = Read-Host "Press Y to start tests, or any other key to exit"
if ($userConsent -cne 'Y') {
    Write-Colored "Run canceled by user." Yellow
    exit 0
}

# --- Main Loop ---
while ($true) {

    if ($doPingTest) {

        if ($counter -eq 0) {
            Write-Colored "Legends: T=Latency(ms) | J=Jitter(ms) | L=PacketLost(Y/N)" Cyan
        }

        $timestamp = Get-Date -Format "HH:mm:ss"

        # Pre-sized List avoids array copy-on-write overhead when adding tasks
        $tasks = [System.Collections.Generic.List[object]]::new($targets.Count)

        foreach ($t in $targets) {
            # Initialise per-target state on first encounter
            if (-not $state.ContainsKey($t.targetHost)) {
                $state[$t.targetHost] = @{
                    sent        = 0
                    recv        = 0
                    lastLatency = $null
                    ewmaJitter  = 0.0
                    # Fixed-size ring buffers avoid RemoveAt(0) shifting overhead.
                    latRing     = New-Object 'double[]' $monitorInterval
                    jitRing     = New-Object 'double[]' $monitorInterval
                    successRing = New-Object 'bool[]' $monitorInterval
                    sampleCursor = 0
                    sampleCount  = 0
                    incidentOpen = $false
                    breachCount = 0
                    nextIncidentAllowedAt = Get-Date
                }
            }

            $state[$t.targetHost].sent++
            $effectivePingTimeoutMs = $pingTimeoutMs
            if ($null -ne $t.timeoutMs -and [int]$t.timeoutMs -gt 0) {
                $effectivePingTimeoutMs = [int]$t.timeoutMs
            }
            $ping, $task = Start-PingAsync -targetHost $t.targetHost -timeoutMs $effectivePingTimeoutMs
            $tasks.Add([PSCustomObject]@{ Target = $t; Ping = $ping; Task = $task })
        }

        [Threading.Tasks.Task]::WaitAll(($tasks | ForEach-Object { $_.Task }))

        Write-Host "$timestamp " -NoNewline
        foreach ($entry in $tasks) {
            $t     = $entry.Target
            $s     = $state[$t.targetHost]
            $reply = $entry.Task.Result

            if ($reply.Status -eq [System.Net.NetworkInformation.IPStatus]::Success) {
                $lat  = $reply.RoundtripTime
                $s.recv++
                $jit  = if ($null -ne $s.lastLatency) { [math]::Abs($lat - $s.lastLatency) } else { [double]::NaN }
                $s.lastLatency = $lat

                if (-not [double]::IsNaN($jit)) {
                    $s.ewmaJitter = [math]::Round((($jitterEwmaAlpha * $jit) + ((1 - $jitterEwmaAlpha) * [double]$s.ewmaJitter)), 2)
                }

                $idx = [int]$s.sampleCursor
                $s.latRing[$idx] = [double]$lat
                $s.jitRing[$idx] = [double]$jit
                $s.successRing[$idx] = $true
                $s.sampleCursor = (($idx + 1) % $monitorInterval)
                if ($s.sampleCount -lt $monitorInterval) { $s.sampleCount++ }

                $latTag  = Get-RateTag $lat  40 80
                Write-Host "[" -NoNewline
                Write-Host $t.name -NoNewline
                Write-Host ("|T:{0}ms" -f $lat)  -ForegroundColor $latTag.color  -NoNewline

                if (-not [double]::IsNaN($jit)) {
                    $jitTag = Get-RateTag $jit 15 30
                    Write-Host ("|J:{0}ms" -f $jit) -ForegroundColor $jitTag.color -NoNewline
                }
                else {
                    Write-Host "|J:n/a" -ForegroundColor DarkGray -NoNewline
                }

                Write-Host "|L:" -NoNewline
                Write-Host "N" -ForegroundColor Green -NoNewline
                Write-Host "]" -NoNewline
            } else {
                $idx = [int]$s.sampleCursor
                $s.latRing[$idx] = [double]::NaN
                $s.jitRing[$idx] = [double]::NaN
                $s.successRing[$idx] = $false
                $s.sampleCursor = (($idx + 1) % $monitorInterval)
                if ($s.sampleCount -lt $monitorInterval) { $s.sampleCount++ }

                Write-Host ("[{0}|T:timeout|J:n/a|L:" -f $t.name) -NoNewline
                Write-Host "Y" -ForegroundColor Red -NoNewline
                Write-Host "]" -NoNewline
            }

            # Dispose Ping to free the underlying socket immediately
            $entry.Ping.Dispose()
        }
        Write-Host ""
    }

    # --- Every N seconds: print per-target summaries and run speedtest ---
    $counter++
    if ($counter -ge $monitorInterval) {

        if ($doPingTest) {
            Write-Host ""
            Write-Host "=== Ping Summary (per gateway) ==="
            foreach ($t in $targets) {
                $s = $state[$t.targetHost]
                $stats = Get-TargetWindowStats -TargetState $s
                $sessionLoss = if ($s.sent -gt 0) { [math]::Round((($s.sent - $s.recv) / $s.sent) * 100, 2) } else { 0.0 }
                Write-TargetLine $t.name $t.targetHost $stats.AvgLatency $stats.AvgJitter $sessionLoss

                Write-Host ("  Percentiles -> P50:{0}ms P95:{1}ms P99:{2}ms | EWMA Jitter:{3}ms | Timeouts:{4}/{5}" -f $stats.P50Latency, $stats.P95Latency, $stats.P99Latency, $stats.EwmaJitter, $stats.TimeoutCount, $stats.SentInWindow)


                # Per-target thresholds (override global if present)
                $latencyThreshold = if ($t.PSObject.Properties["avgLatencyThresholdMs"] -and $t.avgLatencyThresholdMs -ne $null) { [double]$t.avgLatencyThresholdMs } else { $incidentAvgLatencyThresholdMs }
                $jitterThreshold  = if ($t.PSObject.Properties["avgJitterThresholdMs"] -and $t.avgJitterThresholdMs -ne $null) { [double]$t.avgJitterThresholdMs } else { $incidentAvgJitterThresholdMs }

                $isBreach = (
                    ($stats.FinalLoss -ge $incidentLossThresholdPercent) -or
                    ($stats.AvgLatency -ge $latencyThreshold) -or
                    ($stats.AvgJitter -ge $jitterThreshold)
                )

                if ($isBreach) {
                    $s.breachCount++
                }
                else {
                    if ($s.incidentOpen) {
                        Write-Colored ("> Incident recovered for {0} ({1})" -f $t.name, $t.targetHost) Green
                    }
                    $s.breachCount = 0
                    $s.incidentOpen = $false
                }

                if (
                    $incidentDiagnosticsEnabled -and
                    $isBreach -and
                    ($s.breachCount -ge $incidentConsecutiveBreachSummaries) -and
                    (-not $s.incidentOpen) -and
                    ((Get-Date) -ge $s.nextIncidentAllowedAt)
                ) {
                    $s.incidentOpen = $true
                    $s.nextIncidentAllowedAt = (Get-Date).AddSeconds($incidentCooldownSeconds)
                    Write-Colored (
                        "> Incident detected for {0} ({1}) | Breach count: {2}" -f $t.name, $t.targetHost, $s.breachCount
                    ) Red
                    Invoke-IncidentDiagnostics -Target $t -Stats $stats -DnsHosts $healthDnsHosts -TcpTargets $healthTcpTargets -HttpUrls $healthHttpUrls -TcpTimeoutMs $healthTcpTimeoutMs -HttpTimeoutSeconds $healthHttpTimeoutSeconds
                }
            }

            if ($healthChecksEnabled) {
                Invoke-ServiceHealthChecks -DnsHosts $healthDnsHosts -TcpTargets $healthTcpTargets -HttpUrls $healthHttpUrls -TcpTimeoutMs $healthTcpTimeoutMs -HttpTimeoutSeconds $healthHttpTimeoutSeconds
            }
        }

        if ($doSpeedtest -and $doPingTest) {
            $now = Get-Date
            if ($now -lt $speedtestNextAllowedAt) {
                $remaining = [math]::Max(1, [int](($speedtestNextAllowedAt - $now).TotalSeconds))
                Write-Colored ("> Speedtest skipped: cooldown active ({0}s remaining)" -f $remaining) Yellow
            }
            else {
                Write-Host "=== Running Speedtest ==="
                $stResult = Invoke-Speedtest -ServerId $speedtestServerId -SpeedtestExePath $speedtestExePath
                Write-Host ("> Speedtest | DL:{0}Mbps  UL:{1}Mbps" -f $stResult.Download, $stResult.Upload)

                if ($stResult.RateLimited) {
                    $speedtestNextAllowedAt = (Get-Date).AddSeconds($speedtestRateLimitCooldownSeconds)
                    Write-Colored ("> Speedtest cooldown active until {0}" -f $speedtestNextAllowedAt.ToString("HH:mm:ss")) Yellow
                }
            }
        }

        # Separator between summary batches
        Write-Host ""
        Write-Host ""
        Write-Host ""

        if ($delayAfterSummaryMs -gt 0) {
            Start-Sleep -Milliseconds $delayAfterSummaryMs
        }

        $counter = 0
    }

    if ($pingIntervalMs -gt 0) {
        Start-Sleep -Milliseconds $pingIntervalMs
    }
}

:__PWSH_END__

