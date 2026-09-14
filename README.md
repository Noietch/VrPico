# EVA-VR Relay for macOS

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

## Remote EVA-CLIENT

Run the node on the remote machine and bind it to a reachable interface. The
native PICO option uses the fixed test token `eva`:

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
must also be running with the same ZMQ endpoints.

## Mac setup

The distributed `.app` contains its own ADB binary. No Android SDK or
Homebrew installation is needed.

1. Install `EVA-VR.apk` on PICO once.
2. Enable USB debugging and accept the authorization prompt.
3. Open the relay settings and enter the remote server IP/hostname.
4. Keep the port at `43876` unless the remote node uses another port.
5. Click **连接并启动 EVA-VR**.

The app will:

1. Test the remote TCP port.
2. Start a local TCP relay.
3. Create `adb reverse tcp:43876 tcp:43876`.
4. Launch `org.eva.pico.input/.MainActivity`.
5. Pass `ws://127.0.0.1:43876/ws?token=eva` to the native APK.

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
- **PICO unauthorized**: confirm USB debugging in the headset.
- **Relay has no traffic**: confirm `EVA-VR` is installed and the app is
  connected to the same port shown in the relay settings.
- **No vibration**: vibration is sent only when EVA emits an explicit
  `haptic` message; ordinary input frames do not vibrate the controllers.
