# Planned network observability and filtering

Plan only. Nothing here is built.

Future work may add per-sandbox egress monitoring and filtering. There are two
ways to get it, and they differ in what the host is allowed to see:

- **A per-instance gateway.** Each Internet-enabled instance reaches the network
  only through a userspace process Sandfort owns, one per instance. Preferred.
- **A host content filter.** A signed Network Extension inspects flows for the
  whole Mac and reports the ones attributable to UTM. Recorded below as the
  alternative, because it was the first design considered and the reasons it
  lost are worth keeping.

Whichever is built: do not modify Packet Filter rules, routing tables, install
packet-capture shell tools, or add unreviewed QEMU arguments.

## Preferred design: a per-instance gateway

Give each Internet-enabled instance a host-only network and exactly one gateway
process, and make that process the instance's only path off the machine.

Three properties follow from the shape rather than from the implementation, which
is the whole reason to prefer it.

**Attribution is structural.** One process per instance means a flow's origin is
known because of which process observed it, not inferred. The content-filter plan
needs step 2 below to prove attribution is even possible; this design has nothing
to prove. That matters specifically because UTM's Emulated VLAN is QEMU's
user-mode stack: the guest's traffic is translated inside the UTM process and
leaves as UTM's own sockets, so the guest MAC never reaches the host and two
concurrent instances are indistinguishable from outside.

**Denied attempts are visible.** A host content filter sees connections that were
made. A gateway sees connections that were *attempted*, including the ones it
refuses. That closes the gap described under the alternative, where "no observed
traffic" cannot be presented as proof that nothing was tried.

**Nothing outside the sandboxes is ever observed.** A content filter receives
every flow on the Mac from every application and is trusted to ignore what is not
UTM's. A gateway is handed only what its own instance sends it. For an
application whose claim is that it cannot see into things, the difference is not
a detail: one is a policy in Sandfort's code, the other is a fact about what
Sandfort is connected to.

It also removes Apple from the critical path — no NetworkExtension entitlement
request, no system extension, no consent flow, no uninstall story.

### What has to change

Instances are currently built with a single emulated interface, in
`UTMBundleBuilder.writeConfiguration`:

```
"Network": [[
    "Hardware": "virtio-net-pci",
    "IsolateFromHost": !setupMode,
    "MacAddress": randomMACAddress(),
    "Mode": "Emulated",
    "PortForward": []
]]
```

`Mode` is what moves. **Emulated** gives the guest NAT for free inside QEMU,
which is exactly why nothing on the host can attribute it. A host-only mode
gives the instance a network whose only other occupant is the host, and the
gateway supplies the forwarding QEMU stops supplying.

The enforcement property depends on there being no second route. A guest
*configured* to use a proxy is a guest whose root user can unconfigure it; a
guest with no path to the Internet except one interface cannot route around it,
because there is nowhere else to go. Keep it that way: the gateway must be the
absence of an alternative, never a setting inside the guest.

### Open questions to settle before phase 1

1. **Does UTM expose a host-only mode through the configuration plist, and under
   what key value?** `Mode` is `Emulated` today. UTM's other modes and their
   exact spellings are unverified here and must be read out of the installed
   UTM's source the way `docs/utm-version-audit.md` records every other key,
   not guessed from its UI labels.
2. **What does `IsolateFromHost` mean once the host is the gateway?** It is
   currently the offline/online switch. A design whose whole premise is that the
   guest talks to a host process needs this re-derived rather than reused, and
   whatever it becomes must still be reasserted by `repairBundle`.
3. **How much of a NAT does the gateway have to be?** Forwarding TCP and UDP for
   one guest is not the same problem as being a general-purpose router, and the
   answer decides whether this is a weekend or a quarter.
4. **What happens to a running instance if the gateway dies?** The instance must
   lose the network, not silently fall back to an unmediated path.
5. **Does a host-only interface still satisfy the isolation guarantees** that
   `docs/security-model.md` currently attributes to `IsolateFromHost` on an
   emulated interface? This is the question that can sink the design, and it
   should be answered first.

### Invariants the gateway does not get to relax

- No bridged networking and no inbound port forwarding, in any mode. The gateway
  carries traffic outward; nothing dials in.
- **Never terminate or inspect TLS.** The gateway sees addresses, ports, and
  byte counts. It does not become a man in the middle to recover hostnames or
  paths, whatever the analytical temptation. Item 6 below applies unchanged.
- Offline stays exactly as it is, and remains the default.
- Fail closed. If the gateway is unavailable, a monitored run does not start.
- Logs are metadata only, and never contain the guest password or the custom
  setup script.

## Alternative: a host content filter

Kept because the reasoning is worth preserving, not because it is next. Treat it
as a separate signed Network Extension/system-extension project, not a small UTM
configuration change, and follow Apple's supported content-filter APIs.

Two costs decided it. The extension would receive every network flow on the Mac,
so restricting it to UTM is a promise in Sandfort's code rather than a boundary
the system enforces. And the entitlement is Apple's to grant, on Apple's
schedule, before any of the rest can be tested.

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
A host content filter generally cannot observe attempts that UTM blocks inside a
truly offline network. Logging attempted offline connections would require
guest-side telemetry (tamperable by guest root) or a dedicated gateway that
receives, records, and denies traffic. Preserve this distinction in the UI:
"no observed traffic" must never be presented as proof that no connection was
attempted. A gateway is the one design that does not have to.

## Requirements either design must meet

These are about what the feature promises the user, so they do not change with
the mechanism underneath.

1. Keep **Offline** unchanged as the safest mode, and default. Add **Monitored
   Internet** only once the monitor is active and healthy. Decide separately
   whether a direct, unmonitored Internet mode remains available.
2. Record metadata only: timestamp, environment ID, instance number, destination
   IP, destination port, protocol, allow/block verdict, byte counts, and a domain
   name only when it is genuinely observable from plaintext DNS or equivalent
   flow metadata.
3. Do not promise full URLs or complete domain visibility. HTTPS paths are
   encrypted; encrypted DNS and TLS ECH can hide hostnames. Never capture packet
   payloads, credentials, request bodies, cookies, or other content, and never
   terminate TLS to recover them.
4. Add an in-app activity view with filters for environment, instance, time,
   domain, IP, protocol, and verdict. Include pause, clear, configurable
   retention, and metadata-only JSONL/CSV export.
5. Store logs under an app-owned `Network Logs/<environment-id>/<instance-id>`
   hierarchy with per-run identifiers. Apply bounded retention and make log
   deletion explicit and recoverable where practical. Never include the guest
   password or custom setup script.
6. Add reviewed allowlist and denylist policies with clear precedence and a safe
   failure mode. If the monitor is unavailable, a requested monitored run must
   fail closed rather than silently launch with unrestricted Internet.
7. Test DNS, direct IP connections, TCP, UDP, ICMP, IPv4, IPv6, encrypted DNS,
   concurrent instances, monitor restarts, app crashes, sleep/wake, and UTM
   upgrades before release.
8. Monitored Internet writes a record of what the user did to disk on their Mac,
   which Sandfort has never done before. Update `docs/security-model.md` and the
   project site in the same commit that ships it, the way every other
   security-relevant change is handled.

Primary references:

- UTM QEMU network behavior:
  <https://docs.getutm.app/settings-qemu/devices/network/network/>
- Apple Network Extension content filters:
  <https://developer.apple.com/documentation/networkextension/content-filter-providers>
- Apple TN3120, including why packet tunnels are not content filters:
  <https://developer.apple.com/documentation/technotes/tn3120-expected-use-cases-for-network-extension-packet-tunnel-providers>
- Apple TN3134 provider deployment:
  <https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment>

