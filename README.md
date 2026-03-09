A super simple disk space monitor tray icon for macos
=====================================================

Shows the percentage of disk space used in the menu bar. Turns yellow when the
disk is 80% full, and red when it's 90% full. Updates every 5 minutes. That's
it.

Run Once
--------

```sh
swift run
```

Start At Login (LaunchAgent)
----------------------------

Install and start:

```sh
./scripts/install-launchagent.sh
```

Uninstall:

```sh
./scripts/uninstall-launchagent.sh
```
