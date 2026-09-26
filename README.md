# EVA-VR for macOS

This menu-bar app connects a USB-attached PICO headset to a remote
`EVA-CLIENT` native WebSocket node.

It is only needed when the PICO cannot reach the remote server directly and
must use the Mac as an ADB/USB network bridge. If PICO and the EVA server are
on the same reachable network, start `EVA-VR` on PICO directly and do not use
this relay.

## Architecture

```text
PICO EVA-VR APK
    │ ws://127.0.0.1:43876/ws?token=eva
    │ USB + adb reverse
Mac EVA-VR Relay
    │ TCP relay
    ▼
Remote EVA-CLIENT :43876
```

The relay does not parse WebSocket frames. It forwards TCP bytes in both
directions, so pose/button frames and explicit haptic requests use the same
connection.

## EVA-CLIENT

Start EVA-CLIENT normally, select `EVA-VR (PICO)` under Devices, then start
Operation. VrPico can start the selected teleop service through the local or
remote EVA Console API when needed. The native input service defaults to port
`43876`; VrPico's **EVA-VR 端口** defaults to `8417`, the port the standalone
collection stack binds, so change it only when your node listens elsewhere.

The node's access token is read from the console's `browser_url` on every
connect, so VrPico works with both token modes:

- `--token <value>` — a fixed token. The `eva` default is used only when the
  console reports none.
- `--token-stdin` — the node mints a random token at each start. VrPico passes
  the live value to the APK, so restarting the node does not strand the headset.

A node started **outside** the console owns no `browser_url`, so its token
cannot be discovered. **EVA-VR token** covers that case, and VrPico prefills it
with the collection stack's fixed token; change it only when your node uses a
different `--token`. With a token filled in, VrPico uses it instead of guessing
`eva`, and skips the console start request so it never collides with the node's
own ports.

VrPico hands the endpoint to the APK through
`am start --es server_url 'ws://127.0.0.1:<port>/ws?token=<live>'`. EVA-VR v0.2.5
reads that extra; older builds hardcoded `token=eva` and will be rejected with
`401 Unauthorized` against a `--token-stdin` node.

### Using your own SSH tunnel

When the remote host does not expose port `43876` publicly, forward it yourself
and VrPico will reuse that listener instead of starting its own relay:

```bash
ssh -N -p 8000 \
  -L 8415:127.0.0.1:8415 \
  -L 8416:127.0.0.1:8416 \
  -L 43876:127.0.0.1:43876 \
  user@remote-host
```

Add `-o ServerAliveInterval=15 -o ServerAliveCountMax=2 -o ExitOnForwardFailure=yes`
so a dropped tunnel fails loudly instead of leaving dead forwards behind.
VrPico only creates a Mac-side relay when loopback is free, and never removes a
listener it did not create.

For a remote Linux host, bind the native input node to a reachable interface
and make both the Console API and port `43876` reachable from this Mac. A
standalone node can also be launched for debugging:

```bash
cd /path/to/EVA-CLIENT
.venv/bin/python examples/input_sources/vr_webxr/node.py \
  --host 0.0.0.0 \
  --port 43876 \
  --token eva \
  --endpoint tcp://127.0.0.1:8765 \
  --ack-endpoint tcp://127.0.0.1:8766
```

Open TCP port `43876` through the VPN or firewall. The remote EVA process
must also be running with the same ZMQ endpoints. The fixed token is not a
substitute for VPN, firewall rules, or TLS on an untrusted network.

## Mac setup

The distributed `.app` contains its own ADB binary and the tested
`EVA-VR v0.2.5` APK. No Android SDK, Homebrew, or manual APK installation is
needed.

Download `EVA-VR-macOS-v0.2.5.zip` from the [latest release](https://github.com/Noietch/VrPico/releases/latest),
unzip it, and open `VrPico.app`. The app is ad-hoc signed, not Apple notarized;
macOS may require removing the quarantine attribute after downloading:

```bash
xattr -dr com.apple.quarantine VrPico.app
```

1. Enable USB debugging and accept the authorization prompt.
2. Open settings and enter the EVA Client and Viser addresses as `IP:port`. The
   defaults target the collection stack (`33.229.145.163`, ports
   `8415`/`8416`/`8417`, fixed token prefilled), so for that setup nothing
   needs changing.
3. Click **连接 EVA**.

The app will:

1. Detect the authorized PICO.
2. Check whether package `org.eva.pico.input` is installed.
3. Install the bundled `EVA-PICO.apk` only when the package is missing.
4. Start or verify the EVA native teleop service (skipped when a token is set).
5. Start a Mac TCP relay only when EVA is remote; local EVA connects directly.
6. Create `adb reverse tcp:<port> tcp:<port>` when it is missing.
7. Launch `org.eva.pico.input/.MainActivity`.
8. Pass `ws://127.0.0.1:<port>/ws?token=<live>` to the native APK.

The main status panel only shows the EVA service, PICO, and EVA-VR states.
ADB, port forwarding, and relay details are handled automatically. Reconnecting
an already installed PICO skips `adb install` and reuses the existing setup.
VrPico checks the single authorized PICO every two seconds. If the headset is
replaced, it automatically installs the bundled APK when needed, creates the
new reverse mapping, and launches EVA-VR once the EVA node is reachable.
To replace an older installed APK with the bundled build, use **安装 EVA-VR**.
EVA-VR v0.2.5 matches the WebXR convention for thumbstick Y: up is negative.

## 手柄反向

When the robot arm moves opposite to the controllers (forward becomes
backward, left becomes right), open **手柄反向** in the status panel. The relay
then turns every controller pose 180° about the vertical axis while forwarding,
which is exactly the correction the server-side `base_from_xr_rotation`
override applies — except this one lives on the Mac, so a git reset on a shared
server checkout cannot silently undo it. The toggle is read per frame: it
takes effect on the next controller frame without reconnecting the headset or
restarting anything on the server. It only works through the relay path (a
remote server); a headset on the server's own network does not pass through
this Mac.

## Build

```bash
swift test
scripts/build_app.sh --zip
```

The output is `build/VrPico.zip`. The app bundle includes the required ADB
binary and does not require Android Studio, Unity, or a separate runtime.

## Troubleshooting

- **Remote port unreachable**: confirm the remote node uses `--host 0.0.0.0`,
  the port is open, and the Mac is on the required VPN. If the port is firewalled
  but the console answers on `8415`, use your own SSH tunnel (above), or point
  **EVA-VR 端口** at a port the firewall does allow.
- **`HOST: DISCONNECTED` on the headset**: the APK reached the Mac but the relay
  could not reach the node. A node started outside the console commonly binds a
  port of its own, so check that **EVA-VR 端口** matches it — a mismatch looks
  exactly like a dead server.
- **Headset keeps reconnecting / node logs `401 Unauthorized`**: the APK is
  older than v0.2.5 and hardcodes `token=eva`, or the configured token does not
  match the node's. Reinstall with **安装 EVA-VR**; a `--token-stdin` node mints
  a random token the old build cannot know, and a node started outside the
  console needs **EVA-VR token** filled in.
- **Node logs `400 Bad Request` in a loop**: something is opening TCP to the
  native port without a WebSocket handshake. VrPico probes with a real handshake
  after the first connect, so a steady stream points at another tool.
- **PICO unauthorized**: confirm USB debugging in the headset. After you accept
  the authorization prompt, VrPico adopts the new PICO automatically.
- **Robot moves opposite to the controllers**: toggle **手柄反向** on. If the
  pose was correct before and flipped after a server-side git operation, this
  replaces that lost config override permanently — see the 手柄反向 section.
- **No input**: confirm `EVA-VR` is installed and that Operation is started in
  EVA-CLIENT. The native input service defaults to port `43876`.
- **No vibration**: vibration is sent only when EVA emits an explicit
  `haptic` message; ordinary input frames do not vibrate the controllers.
