# Configuration Keys Reference

This file documents all keys in `config.json`.

## Top-level keys

### `speedtest`
Speedtest CLI settings.

- `enabled`: Enable or disable speedtest runs.
- `serverId`: Optional single Ookla server ID.
  - `null` means use automatic server selection.
- `summaryAfterSeconds`: How often to run speedtest (seconds).
- `runOnStart`: If `true`, run speedtest once at startup.
- `rateLimitCooldownSeconds`: Cooldown duration after a 429/rate-limit response.
- `autoInstallCli`: If `true`, auto-download and install Speedtest CLI when missing.
- `cliPath`: Optional explicit path to speedtest.exe.
- `cliDownloadUrl`: Download URL for Speedtest CLI ZIP when auto-install is enabled.

Example:
```json
"speedtest": {
  "enabled": true,
  "serverId": null,
  "summaryAfterSeconds": 600,
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
- `monitorIntervalSecond`: Summary interval for ping sections and loop-based timers.
- `ignoreGoogleDns`: If `true`, do not auto-add Google DNS (`8.8.8.8`). If `false`, auto-add when missing.
- `pingTargets`: Array of ping targets.
  - `name`: Display name shown in output.
  - `host`: Hostname or IP address to ping.

Example:
```json
"pingTest": {
  "enabled": true,
  "monitorIntervalSecond": 60,
  "ignoreGoogleDns": false,
  "pingTargets": [
    { "name": "Cloudflare DNS", "host": "1.1.1.1" },
    { "name": "Home Gateway", "host": "192.168.2.1" }
  ]
}
```

## Notes

- Speedtest CLI is resolved from `speedtest.cliPath`, a bundled `speedtest.exe` beside the app/script, `%LocalAppData%\network-monitor\tools\speedtest.exe`, PATH, or auto-downloaded when `speedtest.autoInstallCli` is true.
- `intervalSecond` is still accepted for backward compatibility, but `summaryAfterSeconds` is preferred.
- `cooldownAfter429Second` is still accepted for backward compatibility, but `rateLimitCooldownSeconds` is preferred.
- Current script includes backward compatibility for legacy keys (`log`, `speedTestTarget`, `tests.doSpeedtest`, `tests.doPingTest`, `tests.monitorIntervalSecond`, top-level `ignoreGoogleDns`, and top-level `pingTargets`).
