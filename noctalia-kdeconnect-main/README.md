# Noctalia KDE Connect (v5)

A Noctalia v5 (Luau) port of the legacy v4 QML plugin by WerWolv, integrating your mobile devices into a panel using KDE Connect.

<img width="430" height="504" alt="image" src="https://github.com/user-attachments/assets/207e0ba8-43d0-432f-b291-d29f89027cbb" />

## Features

- Support for multiple devices, with a persisted "main device" selector
- Bar widget: connection-state glyph + battery percentage of the main device
  - Left click opens the device panel
  - Right-click and middle-click actions are configurable per-widget: None, Open panel, Find device (ring), Ping, Send clipboard, Refresh devices (default None for both)
  - Optional "hide when no device is reachable"
- Control-center shortcut tile showing device name, battery, and connection state
- Device panel:
  - Battery charge + charging state, mobile network type, signal strength, notification count
  - Ring (find my phone), ping, send clipboard text, wake up the screen
  - Send a file (type or paste a path), browse device files over SFTP
  - Pair (with verification key) / unpair
  - Clear error states when `busctl` is missing or `kdeconnectd` is not running
  - Note: `open_near_click` is declared in the manifest but has no effect yet — as of Noctalia v5.0.0-beta2, panel toggles from Luau plugins (bar widget, control-center tile, or CLI) never carry the click position, so the panel always opens at the default attached position. Upstream limitation; the setting will start working once Noctalia routes plugin-widget panel toggles through its anchored path.

## Requirements

- `kdeconnectd` running on the user session (install the KDE Connect app)
- `busctl` (part of systemd)
- `sshfs` + `libfuse` for the "Browse files" action (optional)

## Install (Plugin Source - recommended)

Add https://github.com/Antik79/noctalia-plugins as a plugin source in Noctalia v5 settings.
Then enable it under **Settings → Plugins** (the local directory is discovered as a built-in source), add the bar widget from the Add-widget picker, and add the shortcut from the control-center shortcut settings.

## Install (local development)

```sh
mkdir -p ~/.local/share/noctalia/plugins
cp -r kde-connect ~/.local/share/noctalia/plugins/
```

Then enable it under **Settings → Plugins** (the local directory is discovered as a built-in source), add the bar widget from the Add-widget picker, and add the shortcut from the control-center shortcut settings.

## IPC

```sh
noctalia msg panel-toggle antik/kde-connect:panel
noctalia msg plugin antik/kde-connect:monitor all ring      # ring main device
noctalia msg plugin antik/kde-connect:monitor all ping      # ping main device
noctalia msg plugin antik/kde-connect:monitor all refresh   # force rediscovery
```

## Architecture

```
plugin.toml       manifest: service + widget + shortcut + panel + settings
service.luau      polls kdeconnectd over D-Bus (busctl --json=short), publishes
                  one atomic snapshot on the plugin state channel ("kdec")
widget.luau       bar pill, purely state-driven
shortcut.luau     control-center tile, purely state-driven
panel.luau        device panel; runs its own busctl calls for actions
```

The service batches per-device D-Bus reads into a single subprocess per device (`Properties.GetAll` on the device, battery, and connectivity interfaces plus `activeNotifications`), so a poll costs 2 + N processes instead of the legacy's 1 + 10·N.

## Notes vs. the legacy v4 plugin

- v5 has no file-picker widget, so "Send file" takes a path in a text input instead of opening a picker.
- The phone mock-up graphic is gone; "Wake up" is a regular action button (same `remotecontrol` single-click trick).
- `forceOnNetworkChange` is sent once per daemon lifetime and on manual refresh, instead of every poll.
- The main-device preference persists to `main_device.txt` inside the plugin directory (v5 plugins cannot write settings programmatically).

## License & attribution

This plugin is a Noctalia v5 (Luau) port by antik of the original v4 QML plugin "KDE Connect" by WerWolv ([https://github.com/WerWolv/noctalia-kde-connect](https://github.com/WerWolv/noctalia-kde-connect), also distributed via [https://github.com/noctalia-dev/legacy-v4-plugins](https://github.com/noctalia-dev/legacy-v4-plugins)). Both the original and this port are licensed under the GNU GPL v2.0 (see LICENSE).
