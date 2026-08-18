# Agent Notes

## Project Shape

- `Sources/SimBridgeServer` — Foundation-only transport core. `ProtocolServer`
  owns the Unix-domain socket, NDJSON framing, the `hello` handshake,
  last-connection-wins takeover, client-socket hardening, and the
  socket-ownership guard. `SocketClientInfo` carries peer identity.
- `Sources/SimBridgeShell` — AppKit/SwiftUI menu bar shell shared by the
  provider apps: `StatusItemPanelController` (status item + borderless
  persistent panel), `ProviderMode`/`ModeTransitionController`, `IconToggle`,
  `LaunchAtLogin`, `ShellPreferences`.
- `Tests/SimBridgeServerTests` — socket-level tests against a real UDS,
  including the two production incidents this code was hardened against
  (provider wedged by a non-reading client, provider killed by SIGPIPE on a
  dead peer). Keep them passing; they are the regression net for both products.
- Part of the Simsalabim consolidation (see `../PLAN-SIMSALABIM.md`). Seeded
  2026-08-18 from the CAMouflage copies where the products diverged, with
  ImpossiBLE's extras (persistent panel, Command-drag fix, takeover + hello as
  shipped in ImpossiBLE 3.0.0) reconciled in.

## Invariants

- **Dependency arrows only point downward** (suite → products → SimBridgeKit).
  Never import or reference a product from this package, and never add a
  product-specific wire message, model, or view here. The products must remain
  individually installable.
- **Socket discipline lives here, once.** Every accepted client fd gets
  `SO_NOSIGPIPE`, `SO_SNDTIMEO` (2 s), and a 256 KB `SO_SNDBUF` via
  `configureClientSocket(_:)`; a failed write disconnects the client. Without
  this, a suspended simulator app wedges the provider's serial I/O queue —
  and everything behind it, including mode switching — and a write racing a
  teardown SIGPIPE-kills the process.
- **The ownership guard never steals a live socket.** `start()` probes the
  path with `connect()` first and reports `.blocked` when a listener answers;
  only stale files are unlinked. This is what lets a standalone product app
  and the future suite app coexist without silently bouncing clients.
- **`hello` is consumed by the server, never forwarded** to `onMessage`. The
  wire code for takeover stays `clientBusy` so pre-handshake libraries handle
  eviction identically.
- **All handler callbacks (`onMessage`, `onClientConnected`,
  `onClientTeardown`) run on the private serial I/O queue.** Published
  properties update on main. `send(_:)` may be called from any queue and
  executes directly when already on the I/O queue, so replies from `onMessage`
  keep their ordering.
- `ProtocolServer.log()` only updates `lastActivity` for the UI; it does not
  write to the system log. Absence of console output is not evidence of
  failure.

## Adoption Status

| Component | ImpossiBLE | CAMouflage |
|---|---|---|
| `ProtocolServer` (transport, takeover, hello, hardening, guard) | ✅ adopted (2026-08-18) | ✅ adopted (2026-08-18) |
| Shell (panel, mode controller, toggles, launch-at-login) | ✅ adopted (2026-08-18) | ✅ adopted (2026-08-18) |

Adoption notes: both products consume the kit as a URL dependency pinned
`from: "0.1.1"`. ImpossiBLE's `MockServer` and CAMouflage's `MockCameraServer`
are pure domain layers now — they never touch fds, reply via
`transport.send(_:)`, and drop client state in `onClientTeardown`. CAMouflage's
frame plane (its second, binary socket) deliberately stays product-side, as
does each product's icon rendering and ImpossiBLE's document windows. Defaults
keys survived adoption unchanged (ImpossiBLE: `SelectedProviderMode` with the
`ServerEnabled` legacy fallback; CAMouflage: `ProviderMode`), and CAMouflage's
mode transitions deliberately do not bounce through a stop — its two frame
sources are byte-identical on the wire and switch live.

Migration is one component at a time, landing in **both** products before the
next component moves (see PLAN-SIMSALABIM.md, Step 2.3). Client-fixture
lifecycle and the footer acknowledgement toast are deliberately not extracted
yet — they are entangled with product-specific models.

## Validation

```bash
swift build
swift test
```
