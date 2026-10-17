A super simple disk space monitor tray icon for macos
=====================================================

Shows the percentage of disk space used in the menu bar. Turns yellow when the
disk is 80% full, and red when it's 90% full. Updates every 5 minutes. The
refresh interval and warning/error percentages can be changed from
Preferences… in the menu. That's it.

Analyse mode scans a configurable list of folders first (depth first, in
order) before the rest of the filesystem. By default: `/private/tmp`,
`~/Library/Containers/com.docker.docker`, `~/Downloads`,
`~/Library/Logs/Homebrew` and `~/Library/Caches/Homebrew`. Edit the list in
Preferences….

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
