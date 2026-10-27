# Compatibility and recovery

This change was developed against upstream 0.7.0. The local trial builds used
0.9.x identifiers; the proposed final patch version is 0.7.1. It retains the
upstream app ID, title, vendor, release-manifest format and catalogue links.
The build is a contribution candidate, not a maintainer-published release.

## Device checks

| Device | Runtime | DNS mode | Observations |
| --- | --- | --- | --- |
| B9 OLED | webOS 4.10.2, Node 0.12.2, Upstart | IPv4 redirect | Apply, Restore and full-profile reboot passed, including delayed SDP reload; 583 rules and 15 known executable targets blocked. Owner confirmed healthy UI after reboot. |
| UR8050PSB LCD | firmware 33.22.85, webOS 10.2.2, Node 16.20.2, systemd | ConnMan resolver | Kernel explicitly excludes Netfilter. 0.9.7 Apply/Restore and reboot passed, including delayed SDP and late app-jail target maintenance; 582 rules. Final 0.7.1 runtime files match this tested build. |

Firmware and detected paths differ. These checks do not establish universal
support or comprehensive prevention of collection. A domain or executable not
recognized by this app may remain reachable/runnable.

## DNS

Older firmware uses a bounded, read-only ConnMan command-line query when busctl
is absent. Native children clear Homebrew's injected LD_PRELOAD locally; this
avoids an observed old-BusyBox timeout hang without changing Homebrew settings.
Timeout syntax is selected from help, with resolved executable paths and KILL
bounds. Connection discovery retries boot readiness and ambiguity. Multiple
services require a unique stable match of the kernel route's interface AND
source IPv4 address, rechecked around the fresh service snapshot.

Kernels explicitly excluding Netfilter use a typed ConnMan DNS configuration
snapshot and handoff instead of iptables/module loading. The helper listens on
the TV IPv4 address and accepts local-source clients only. Effective and configured
DNS must agree; restoration preserves an empty DHCP array and original address
order, and refuses to overwrite an unrelated external change. Each enable/reload
verifies a generation-specific UDP/TCP query through the actual data path.

ConnMan mode covers the TV resolver. Direct DNS, DoH/DoT, direct IP connections
and unidentified collection components can bypass it. Redirect mode covers IPv4
port 53; encrypted DNS can bypass that too. The optional IPv6-off companion is
reversible and does not provide a universal privacy guarantee.

The helper has no upstream failover or network-change watcher. Reapply after
interface/address/resolver changes. If the helper stops, DNS can remain unavailable
until Restore/reapply. Retain recovery state when an operation fails.

## Services, late targets and restoration

Installed Upstart jobs or systemd units are discovered before control operations.
Only previously running jobs are recorded for selective restoration. systemd stops
are queued before checking completion. Exact known executable paths are stubbed
and process/mount results verified; missing or failed targets remain visible.
A generation-owned worker checks selected known categories every 15 seconds for
late app-jail copies. New copies can run before a pass. Restore invalidates the
worker before removing owned mounts; no broad process-tree signals are used.

Mutations share an atomic lock. The delayed SDP update waits up to 20 seconds for
short maintenance contention and checks its generation before/after acquisition.
An unfinished dead worker remains a visible failure. No lock is stolen; cancelled
workers do not modify a replacement apply. Host mounts are verified by identity
before removal, and failed restoration retains recovery records.

Restore is available separately from the main protection action. Status describes
selected checks rather than claiming complete privacy. Current logs replace the
visible log while retaining the previous run. Cache purge is deliberately disabled:
broad historical wildcard paths also matched live coordination files, and no safe
firmware-specific deletion allowlist has been validated. Do not enable collection
to manufacture sample cache data.

## Validation

Shell regressions use isolated paths/mocked commands and include real lock-worker
contention and cancellation. Private D-Bus tests use real busctl with a fake ConnMan
on a disposable bus, including DHCP/ordered restoration and failed-probe rollback.
DNS unit and smoke tests include local-client restrictions and old Node runtimes.
Package validation checks safe modes/paths and byte identity with application source.
Device commands are exercised through the actual Homebrew exec route; ordinary
DNS and selected blocked ad/SDP names are checked separately from status output.
Private captures, identifiers, network addresses and backups are excluded from
this contribution. The UI/normal-viewing effects of optional blocks still require
owner acceptance on each firmware; voice, casting, Channels and update blocks
intentionally make their corresponding functions unavailable.

Final automated checks: 69 shell/lifecycle cases, 14 frontend checks, four real
private-D-Bus scenarios and 22 DNS unit tests passed. Smoke suites passed with
Node 0.12.2, 0.12.18, 8.12.0 and 16.20.2. The final 0.7.1 IPK runtime files
are byte-identical to the 0.9.7 device candidate; app/package version and branding
metadata are the only differences. Both devices passed startup and the delayed
SDP phase on that runtime. On the LCD all then-detected ad/voice/ThinQ targets
were blocked, ordinary DNS worked and selected ad/SDP names were blocked.
Its saved profile, including QuickSet off and purge off, was preserved.

The final 0.7.1 package was installed on the LCD after a successful Restore.
Homebrew Enable and status passed after the full SDP interval: 582 rules,
maintenance running and 21/21 ad, 15/15 voice, 14/14 ThinQ targets blocked.
All 31 installed files matched final source. Ordinary DNS worked and selected
ad/SDP domains were blocked; settings remained unchanged. Protection/autostart
remain enabled. The app was opened for the owner to check normal viewing.
