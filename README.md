# SimBridgeKit

**The shared foundation of the Simsalabim simulator-retrofitting products.**

[ImpossiBLE](https://github.com/mickeyl/ImpossiBLE) (CoreBluetooth) and
[CAMouflage](https://github.com/mickeyl/CAMouflage) (AVFoundation capture)
bridge missing hardware into the iOS Simulator with the same architecture: a
swizzling library in the simulator app talks newline-delimited JSON over a Unix
domain socket to a menu bar provider app on the Mac. SimBridgeKit is the code
they used to duplicate — extracted once, hardened once, tested once.

## Products

### `SimBridgeServer` (Foundation only)

`ProtocolServer` — the host side of a retrofitting wire protocol:

- Unix-domain socket lifecycle with NDJSON framing; domain messages are handed
  to `onMessage`, replies go out through `send(_:)`.
- **`hello` handshake**: client identity (peer pid/process at accept, library
  version and bundle id from `hello`) published as `connectedClient`; version
  skew against the provider's own version is logged instead of staying silent.
- **Last-connection-wins takeover**: a freshly launched simulator app takes
  over the slot; the previous client receives `connectionRejected {clientBusy}`
  (so its library stops auto-reconnecting) and `onClientTeardown(.superseded)`
  tells the domain layer to drop its state.
- **Hardened client sockets**: `SO_NOSIGPIPE` (a write racing a client teardown
  returns an error instead of killing the provider), `SO_SNDTIMEO` plus a
  256 KB send buffer (a client that stops reading is disconnected instead of
  wedging the I/O queue in a blocking `write()`).
- **Socket-ownership guard**: before binding, a live listener on the path is
  probed; if one answers, the server reports `.blocked` instead of stealing
  the socket. Only stale files nobody answers on are unlinked.

### `SimBridgeShell` (AppKit / SwiftUI)

The provider apps' menu bar shell:

- `StatusItemPanelController` — status item with the borderless, persistent
  control panel underneath (Command-drag passthrough, positioning,
  dismiss-on-deactivate behavior).
- `ControlPanel` / `MenuPanelContentView` — the panel chrome.
- `ProviderMode` + `ModeTransitionController` — the Off / Mock / Passthrough
  selection with serialized transitions.
- `IconToggle`, `LaunchAtLogin`, `ShellPreferences` — footer toggles,
  LaunchAgent handling, shared preference keys.

## Dependency rule

Arrows only point downward:

```
Simsalabim (suite) → ImpossiBLE / CAMouflage (products) → SimBridgeKit
```

SimBridgeKit must never depend on a product, and no product-specific wire
message, model, or view belongs here. Anything that violates this breaks the
products' standalone installability.

## Usage

```swift
import SimBridgeServer

let server = ProtocolServer(socketPath: "/tmp/impossible.sock",
                            name: "ImpossiBLE-Mock",
                            appVersion: "3.0.0")
server.onMessage = { message in /* domain protocol */ }
server.onClientTeardown = { reason in /* drop client state */ }
server.start()
```

## Validation

```bash
swift build
swift test    # exercises hello, takeover, ownership guard, peer-death survival
```

## License

MIT — see [LICENSE](LICENSE) for details.
