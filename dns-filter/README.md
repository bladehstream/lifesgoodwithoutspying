# DNS compatibility helper

Build: `bun install --frozen-lockfile && bun run build`.
Tests: `bun test` and `bun run smoke`. Parent README covers the two TVs.

`tv-handoff.sh plan` is read-only and reports the automatically selected mode.
`NOSPY_DNS_MODE=redirect|connman` overrides auto for controlled testing.

## Redirect mode

On the B9, the helper listens on 127.0.0.1:5354 and IPv4 NAT OUTPUT redirects
UDP/TCP port 53 to it. Dedicated upstream source ports avoid recursion.
Stateful cleanup removes only recorded rules. The opt-in IPv6-off companion
retains the previous automatic/off method and mounts an IPv4-only resolv.conf.

## ConnMan mode

Auto detects a kernel explicitly built with CONFIG_NETFILTER unset, as on the
UR8050PSB. It requires busctl and does not invoke iptables or load modules.
The helper binds the active TV IPv4 address on port 53 and is started with
`--local-clients-only`. A non-loopback CLI listener without that flag is refused.
UDP sources outside the TV's assigned addresses are ignored; TCP peers outside
that set are closed. This is source-address filtering, not cryptographic client
identity or a replacement for a firewall against forged-source traffic.

ConnMan can bind upstream DNS sockets to the physical interface, so simply
using 127.0.0.2 as its nameserver is unreliable. Its original DNS configuration
array (including an empty DHCP array) is captured through typed D-Bus properties
before a write. The helper starts before Nameservers.Configuration is changed.
Both configured and effective nameservers must point at the helper. Restoration
preserves original DNS order and refuses to overwrite unrelated external changes.
Failed restoration retains state and the helper for inspection and retry.

This covers clients using ConnMan's resolver. Direct DNS, DoH/DoT, direct IPs
and unidentified collection components can bypass it. Nothing changes the
router DNS, default route, Wi-Fi credentials or IP configuration.

## Verification and recovery

Both modes must pass a generation-specific UDP/TCP health query through the
actual resolver/redirect before enable succeeds. The reserved TXT health name
never goes upstream, has TTL zero, and changes with the rule generation.
If the path fails, enable attempts rollback. Status also requires a live verified
helper, matching generation, correct network path and a successful health probe.
This proves the path reaches this helper; it does not prove comprehensive privacy.

`disable` restores the recorded handoff; `reload` acknowledges the new artifact
or retains the previous generation with failure status. No automatic upstream
failover or network watcher is implemented. Reapply after interface/DNS/address
changes. A stopped helper can leave DNS unavailable until restore/reapply.
A forced kill or power failure can interrupt rollback; retain the state files.

The artifact starts with:

    # lifesgoodwithoutspying dns-filter generation TOKEN rules COUNT

Plain rules match exactly; *.suffix matches subdomains. Shell operations share
an atomic mutation lock. See `scripts/tv-dns-trial.sh` for a bounded, no-install
trial with automatic restoration and IPv6 preserved.
