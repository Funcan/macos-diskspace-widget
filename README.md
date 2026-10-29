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

Versioning
----------

The version comes from git tags (`git describe --tags --dirty`) and is shown,
along with the commit hash (and a note if the working tree was dirty), under
About in the menu. It's embedded into the binary by `scripts/build.sh`
(used by `make build`, `make install` and CI); a plain `swift build` or
`swift run` shows "unknown".

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
