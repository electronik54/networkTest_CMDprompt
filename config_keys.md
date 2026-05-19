# Config Guide (Easy Language)

This file explains what each entry in config.json does.

## speedtest
Use this section to control internet speed tests (download/upload).

What this test does:

- Runs Ookla Speedtest and measures your internet download and upload speed.
- This checks your internet provider path, not just your local router.

How this helps:

- Confirms if slow internet is really an ISP or broadband speed issue.
- Helps compare "internet is slow" vs "local network is unstable".
- Useful when ping is fine but streaming/download performance is still poor.

- enabled: true = run speedtest, false = skip it.
- serverId: pick a specific Ookla server ID. Use null for auto server selection.
- runOnStart: old setting, kept for compatibility.
- rateLimitCooldownSeconds: if speedtest hits rate limits, wait this many seconds before trying again.
- autoInstallCli: true = download speedtest.exe automatically if missing.
- cliPath: full path to speedtest.exe if you already have it.
- cliDownloadUrl: where to download speedtest CLI zip from.

## pingTest
Use this section for regular ping monitoring.

What this test does:

- Sends repeated ping requests to the targets you list.
- Tracks latency, jitter, and packet loss over time.

How this helps:

- Shows short spikes and instability that one-time tests can miss.
- Helps find if the issue is near your gateway, DNS endpoint, or upstream path.
- Gives early warning before users feel major connection drops.

- enabled: true = ping monitoring is active.
- pingIntervalMilSeconds: delay between pings.
- timeoutMs: default ping timeout for each target.
- healthChecks: extra DNS/TCP/HTTP checks that run with ping summaries.
- pingTargets: list of devices/services to ping.

Each pingTargets item:

- name: label shown in output.
- host: IP or hostname to ping.
- enabled: true = include this target, false = skip this target.
- timeoutMs: optional per-target timeout. If missing, timeoutMs from pingTest is used.
- avgLatencyThresholdMs: optional per-target latency threshold used by incident logic.
- avgJitterThresholdMs: optional per-target jitter threshold used by incident logic.

Important:

- If pingTest.enabled is true but all pingTargets are disabled, the startup prompt will warn you and ping test will not run.

## summary
Controls how often summary output is shown.

What this does:

- Groups many ping results into one summary window.
- Prints averages/percentiles so trends are easier to read.

How this helps:

- Reduces noise from line-by-line ping output.
- Makes it easy to compare "before" and "after" network changes.
- Helps spot gradual degradation, not just sudden failures.

- summaryAfterPings: show summary after this many pings.
- delayAfterSummarySeconds: pause after each summary block.
- jitterEwmaAlpha: smoothing value for jitter trend (between 0 and 1).

## incident
Controls when the script treats network quality as bad and runs extra diagnostics.

What this does:

- Watches summary values (loss/latency/jitter) against thresholds.
- If limits are crossed repeatedly, it marks an incident and runs deeper diagnostics.

How this helps:

- Avoids false alarms from a single random spike.
- Captures extra evidence (for example traceroute and health checks) exactly when the issue is happening.
- Makes troubleshooting faster because context is collected automatically.

- enabledDiagnostics: true = run incident diagnostics when thresholds are crossed.
- lossThresholdPercent: packet loss threshold.
- avgLatencyThresholdMs: latency threshold.
- avgJitterThresholdMs: jitter threshold.
- consecutiveBreachSummaries: how many bad summaries in a row are needed.
- cooldownSeconds: wait time before triggering the same incident again.

## pingTest.healthChecks
These are extra connectivity checks besides ping.

What this test does:

- Verifies real service reachability using DNS, TCP, and HTTP checks.
- Complements ping by testing layers that applications actually use.

How this helps:

- Ping can succeed while apps still fail. Health checks catch those cases.
- Helps separate DNS issues, port/connectivity issues, and website/API issues.
- Gives a clearer root-cause signal for user-facing outages.

When this runs:

- pingTest.healthChecks does not run as a fully separate loop right now.
- It runs during the ping summary cycle.
- This means all of the below must be true:
- pingTest.enabled is true.
- At least one pingTargets item is enabled.
- pingTest.healthChecks.enabled is true.
- At least one pingTest.healthChecks target is enabled (DNS or TCP or HTTP).

If pingTest is disabled, healthChecks will be skipped even if dnsHosts/tcpTargets/httpUrls have enabled entries.

- enabled: true = run health checks.
- dnsHosts: DNS lookup checks.
- tcpTargets: TCP connection checks.
- httpUrls: HTTP reachability checks.
- tcpTimeoutMs: timeout for TCP checks.
- httpTimeoutSeconds: timeout for HTTP checks.

Each dnsHosts item:

- host: domain to resolve (example: www.google.com).
- enabled: true = include, false = skip.

What DNS check means:

- It asks your DNS resolver for IP addresses of the domain.
- Pass means name resolution works for that host.

How DNS check helps:

- Detects DNS outages/misconfiguration quickly.
- Explains "websites not opening" even when ping to IP still works.

Each tcpTargets item:

- host: IP/hostname to connect to.
- port: TCP port.
- enabled: true = include, false = skip.

What TCP check means:

- It tries to open a socket connection to host:port.
- Pass means network path and port access are available.

How TCP check helps:

- Detects firewall, routing, or port-block issues.
- Explains "server reachable by ping, but app still cannot connect".

Each httpUrls item:

- url: website/API URL to test.
- enabled: true = include, false = skip.

What HTTP check means:

- It sends a web request to the URL and checks response status/time.
- Pass means the endpoint is reachable from your machine at application level.

How HTTP check helps:

- Detects proxy/TLS/app-endpoint problems that ping and TCP cannot fully show.
- Confirms whether real user paths (web/API) are working end-to-end.

Important:

- If pingTest.healthChecks.enabled is true but no DNS/TCP/HTTP health target is enabled, startup prompt will warn you and health checks will not run.
- If pingTest.enabled is false (or all pingTargets are disabled), startup prompt will also skip health checks because there is no ping summary cycle to attach to.

## Example

```json
{
  "speedtest": {
    "enabled": false,
    "serverId": null,
    "runOnStart": false,
    "rateLimitCooldownSeconds": 1800,
    "autoInstallCli": true,
    "cliPath": null,
    "cliDownloadUrl": "https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-win64.zip"
  },
  "pingTest": {
    "enabled": true,
    "pingIntervalMilSeconds": 50,
    "timeoutMs": 1000,
    "healthChecks": {
      "enabled": true,
      "dnsHosts": [
        { "host": "www.google.com", "enabled": true }
      ],
      "tcpTargets": [
        { "host": "1.1.1.1", "port": 443, "enabled": true }
      ],
      "httpUrls": [
        { "url": "https://www.msftconnecttest.com/connecttest.txt", "enabled": true }
      ],
      "tcpTimeoutMs": 2000,
      "httpTimeoutSeconds": 5
    },
    "pingTargets": [
      {
        "name": "Google DNS",
        "host": "8.8.8.8",
        "enabled": true,
        "timeoutMs": 1000,
        "avgLatencyThresholdMs": 40,
        "avgJitterThresholdMs": 10
      }
    ]
  }
}
```
