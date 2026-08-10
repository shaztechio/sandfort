# Planned network observability and filtering


Future work may add per-sandbox egress monitoring and filtering. Treat this as a
separate signed Network Extension/system-extension project, not as a small UTM
configuration change. Follow Apple's supported Network Extension content-filter
APIs; do not modify Packet Filter rules, routing tables, install packet-capture
shell tools, or add unreviewed QEMU arguments.

Implementation plan:

1. Prototype a macOS `NEFilterDataProvider` and, if required for pre-NAT
   attribution, `NEFilterPacketProvider`. Package it as an app or system
   extension with the required entitlements, Developer ID signing, user consent,
   and documented uninstall behavior.
2. Prove attribution with two concurrently running Internet-enabled UTM/QEMU
   instances. UTM's Emulated VLAN traffic is presented to macOS as originating
   from the UTM process, so process identity alone is insufficient. Correlate
   only with stable, observed VM metadata such as the instance's unique MAC,
   subnet, or pre-NAT packet context. Never guess the environment from timing.
3. If reliable concurrent attribution is not possible, either introduce a
   dedicated per-instance logging gateway or explicitly restrict monitored
   Internet access to one running instance. Do not show potentially incorrect
   instance attribution as authoritative.
4. Keep **Offline** unchanged as the safest mode. Add **Monitored Internet** only
   after the extension is active and healthy. Decide separately whether a
   direct, unmonitored Internet mode remains available.
5. Record metadata only: timestamp, environment ID, instance number, destination
   IP, destination port, protocol, allow/block verdict, byte counts, and a domain
   name only when it is genuinely observable from plaintext DNS or equivalent
   flow metadata.
6. Do not promise full URLs or complete domain visibility. HTTPS paths are
   encrypted; encrypted DNS and TLS ECH can hide hostnames. Never capture packet
   payloads, credentials, request bodies, cookies, or other content.
7. Add an in-app activity view with filters for environment, instance, time,
   domain, IP, protocol, and verdict. Include pause, clear, configurable
   retention, and metadata-only JSONL/CSV export.
8. Store logs under an app-owned `Network Logs/<environment-id>/<instance-id>`
   hierarchy with per-run identifiers. Apply bounded retention and make log
   deletion explicit and recoverable where practical. Never include the guest
   password or custom setup script.
9. Add reviewed allowlist and denylist policies with clear precedence and a safe
   failure mode. If the monitor/filter is unavailable, a requested monitored run
   must fail closed rather than silently launch with unrestricted Internet.
10. Test DNS, direct IP connections, TCP, UDP, ICMP, IPv4, IPv6, encrypted DNS,
    concurrent instances, extension restarts, app crashes, sleep/wake, and UTM
    upgrades before release.

A host content filter generally cannot observe attempts that UTM blocks inside a
truly offline network. Logging attempted offline connections would require
guest-side telemetry (tamperable by guest root) or a dedicated gateway that
receives, records, and denies traffic. Preserve this distinction in the UI:
"no observed traffic" must never be presented as proof that no connection was
attempted.

Primary references:

- UTM QEMU network behavior:
  <https://docs.getutm.app/settings-qemu/devices/network/network/>
- Apple Network Extension content filters:
  <https://developer.apple.com/documentation/networkextension/content-filter-providers>
- Apple TN3120, including why packet tunnels are not content filters:
  <https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers>
- Apple TN3134 provider deployment:
  <https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment>

