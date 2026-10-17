A super simple disk space monitor tray icon for macos
=====================================================

Shows the percentage of disk space used in the menu bar. Turns yellow when the
disk is 80% full, and red when it's 90% full. Updates every 5 minutes by
default; the refresh interval can be changed from Preferences… in the menu.
That's it.

Preferences are stored via `UserDefaults` in
`~/Library/Preferences/MacDiskMonitor.plist`.

Run Once
--------

```sh
swift run
```

Start At Login (LaunchAgent)
----------------------------

Install and start:

```sh
make install
```

Uninstall:

```sh
make uninstall
```
