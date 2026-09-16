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
remote EVA Console API when needed. The native input service uses port `43876`
and the fixed development token `eva`.

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
`EVA-VR v0.2.3` APK. No Android SDK, Homebrew, or manual APK installation is
needed.

Download `EVA-VR-macOS-v0.2.1.zip` from the [latest release](https://github.com/Noietch/VrPico/releases/latest),
unzip it, and open `VrPico.app`. The app is ad-hoc signed, not Apple notarized;
macOS may require removing the quarantine attribute after downloading:

```bash
xattr -dr com.apple.quarantine VrPico.app
```

1. Enable USB debugging and accept the authorization prompt.
2. Open settings and enter the EVA Client and Viser addresses as `IP:port`.
3. Click **连接 EVA**.

The app will:

1. Detect the authorized PICO.
2. Check whether package `org.eva.pico.input` is installed.
3. Install the bundled `EVA-PICO.apk` only when the package is missing.
4. Start or verify the EVA native teleop service.
5. Start a Mac TCP relay only when EVA is remote; local EVA connects directly.
6. Create `adb reverse tcp:43876 tcp:43876` when it is missing.
7. Launch `org.eva.pico.input/.MainActivity`.
8. Pass `ws://127.0.0.1:43876/ws?token=eva` to the native APK.

The main status panel only shows the EVA service, PICO, and EVA-VR states.
ADB, port forwarding, and relay details are handled automatically. Reconnecting
an already installed PICO skips `adb install` and reuses the existing setup.
VrPico checks the single authorized PICO every two seconds. If the headset is
replaced, it automatically installs the bundled APK when needed, creates the
new reverse mapping, and launches EVA-VR once the EVA node is reachable.
To replace an older installed APK with the bundled build, use **安装 EVA-VR**.

## Build

```bash
swift test
scripts/build_app.sh --zip
```

The output is `build/VrPico.zip`. The app bundle includes the required ADB
binary and does not require Android Studio, Unity, or a separate runtime.

## Troubleshooting

- **Remote port unreachable**: confirm the remote node uses `--host 0.0.0.0`,
  the port is open, and the Mac is on the required VPN.
- **PICO unauthorized**: confirm USB debugging in the headset. After you accept
  the authorization prompt, VrPico adopts the new PICO automatically.
- **No input**: confirm `EVA-VR` is installed and that Operation is started in
  EVA-CLIENT. The native input service uses port `43876`.
- **No vibration**: vibration is sent only when EVA emits an explicit
  `haptic` message; ordinary input frames do not vibrate the controllers.
