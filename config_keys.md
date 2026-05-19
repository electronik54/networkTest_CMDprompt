# Configuration Keys Reference

This file documents all keys in `config.json`.

## Top-level keys

### `speedtest`
Speedtest CLI settings.

- `enabled`: Enable or disable speedtest runs.
- `serverId`: Optional single Ookla server ID.
  - `null` means use automatic server selection.
- `runOnStart`: Legacy startup option. Speedtest now runs only when summary is displayed.
- `rateLimitCooldownSeconds`: Cooldown duration after a 429/rate-limit response.
- `autoInstallCli`: If `true`, auto-download and install Speedtest CLI when missing.
- `cliPath`: Optional explicit path to speedtest.exe.
- `cliDownloadUrl`: Download URL for Speedtest CLI ZIP when auto-install is enabled.

Example:
```json
"speedtest": {
  "enabled": true,
  "serverId": null,
  "runOnStart": false,
  "rateLimitCooldownSeconds": 1800,
  "autoInstallCli": true,
  "cliPath": null,
  "cliDownloadUrl": "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
}
```

### `tests`
Test feature toggles.

- Reserved for compatibility with older config schemas.

Example:
```json
"tests": {
  "doPingTest": true,
  "monitorIntervalSecond": 60
}
```

### `pingTest`
Ping monitoring settings.

- `enabled`: Enable or disable ping monitoring output.
- `summaryAfterPings`: How many pings to run between each summary display.
- `timeoutMs`: ICMP timeout per ping request in milliseconds.
- `ignoreGoogleDns`: If `true`, do not auto-add Google DNS (`8.8.8.8`). If `false`, auto-add when missing.
- `pingTargets`: Array of ping targets.
  - `name`: Display name shown in output.
  - `host`: Hostname or IP address to ping.
  - `avgLatencyThresholdMs`: (optional, per-target) Incident triggers if average latency exceeds this value (ms).
  - `avgJitterThresholdMs`: (optional, per-target) Incident triggers if average jitter exceeds this value (ms).

Example:
```json
"pingTest": {
  "enabled": true,
  "timeoutMs": 1000,
  "summaryAfterPings": 60,
  "ignoreGoogleDns": false,
  "pingTargets": [
    { "name": "Cloudflare DNS", "host": "1.1.1.1", "avgLatencyThresholdMs": 40, "avgJitterThresholdMs": 10 },
    { "name": "Home Gateway", "host": "192.168.2.1", "avgLatencyThresholdMs": 40, "avgJitterThresholdMs": 10 }
  ]
}
```

### `summary`
Summary window settings.

- `summaryAfterPings`: Number of ping iterations in each summary window.
- `delayAfterSummarySeconds`: Delay after each summary block.
- `jitterEwmaAlpha`: Smoothing factor for EWMA jitter (`0 < alpha <= 1`).

Example:
```json
"summary": {
  "summaryAfterPings": 100,
  "delayAfterSummarySeconds": 2,
  "jitterEwmaAlpha": 0.2
}
```

### `incident`
Incident detection and one-time diagnostics trigger settings.

- `enabledDiagnostics`: If `true`, run incident diagnostics when thresholds are breached.
- `lossThresholdPercent`: Loss threshold to mark a breach.
- `avgLatencyThresholdMs`: Average latency threshold to mark a breach.
- `avgJitterThresholdMs`: Average jitter threshold to mark a breach.
- `consecutiveBreachSummaries`: How many summary windows must breach before incident starts.
- `cooldownSeconds`: Cooldown before another incident can trigger for the same target.

Example:
```json
"incident": {
  "enabledDiagnostics": true,
  "lossThresholdPercent": 2,
  "avgLatencyThresholdMs": 120,
  "avgJitterThresholdMs": 30,
  "consecutiveBreachSummaries": 2,
  "cooldownSeconds": 600
}
```

### `healthChecks`
Optional non-ICMP checks to validate user-facing connectivity.

- `enabled`: If `true`, run DNS/TCP/HTTP checks after each summary.
- `dnsHosts`: Hostnames for DNS lookup checks.
- `tcpTargets`: Host/port targets for TCP connect checks.
  - `host`: Hostname or IP.
  - `port`: TCP port (defaults to `443` if omitted).
- `httpUrls`: URLs for HTTP HEAD reachability checks.
- `tcpTimeoutMs`: Timeout for TCP checks.
- `httpTimeoutSeconds`: Timeout for HTTP checks.

Example:
```json
"healthChecks": {
  "enabled": false,
  "dnsHosts": ["www.google.com", "www.cloudflare.com"],
  "tcpTargets": [
    { "host": "1.1.1.1", "port": 443 },
    { "host": "8.8.8.8", "port": 443 }
  ],
  "httpUrls": ["https://www.msftconnecttest.com/connecttest.txt"],
  "tcpTimeoutMs": 2000,
  "httpTimeoutSeconds": 5
}
```

## Notes

- Speedtest CLI is resolved from `speedtest.cliPath`, a bundled `speedtest.exe` beside the app/script, `%LocalAppData%\network-monitor\tools\speedtest.exe`, PATH, or auto-downloaded when `speedtest.autoInstallCli` is true.
- `monitorIntervalSecond` and `summaryAfterSeconds` are still accepted for backward compatibility, but `pingTest.summaryAfterPings` is preferred.
- `pingTimeoutMilSeconds` is still accepted for backward compatibility, but `pingTest.timeoutMs` is preferred.
- `intervalSecond` is still accepted for backward compatibility in legacy `speedTestTarget`, but speedtests now run only on summary display.
- `cooldownAfter429Second` is still accepted for backward compatibility, but `rateLimitCooldownSeconds` is preferred.
- Current script includes backward compatibility for legacy keys (`log`, `speedTestTarget`, `tests.doSpeedtest`, `tests.doPingTest`, `tests.monitorIntervalSecond`, top-level `ignoreGoogleDns`, and top-level `pingTargets`).
