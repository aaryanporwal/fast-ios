# Remove fast-ios

Back to the [README](../README.md).

## The short way

```bash
fast-ios uninstall --dry-run   # list what would be removed; changes nothing
fast-ios uninstall
```

`uninstall` runs `fast-ios off` (every simulator back to full, the
background helper removed), then deletes fast-ios's settings folder, its
cache and its log. It then lists what only you can remove, and how: the
app and its login item, and the `fast-ios` command link (steps 2, 4 and 5
below). It never deletes simulators, so the pool simulators (step 3) stay,
and so do the app's settings (step 7).

## By hand, step by step

You do every step. Run each command in any folder.

1. Turn fast-ios off:

   ```bash
   fast-ios off
   ```

   Every simulator goes back to full, and the background helper
   (`~/Library/LaunchAgents/dev.fast-ios.auto.plist`) is stopped and
   deleted. If you skip this, the helper keeps making new simulators light
   after the app is gone.
2. In the menu-bar app, turn off "Open at login", then click Quit. If the
   app is already gone, remove "fast-ios" in System Settings > General >
   Login Items instead. Otherwise macOS keeps a login item that points at
   nothing.
3. Delete the simulators fast-ios created for leases and templates (names
   start with `fast-ios-lease-` or `fast-ios-template-`):

   ```bash
   xcrun simctl list devices --json | jq -r '.devices[][] | select(.name | test("^fast-ios-(lease|template)-")) | .udid' | xargs -n1 xcrun simctl delete
   ```

   This deletes only those simulators; yours keep their names and are not
   touched. Skip it and they stay in Xcode's list, using disk space.
4. Remove the command. If you installed with Homebrew:

   ```bash
   brew uninstall fast-ios
   ```

   Otherwise, remove the link the script or the app made:

   ```bash
   link=$(command -v fast-ios) && [ -L "$link" ] && rm "$link"
   ```

   This removes only a link, never a real file.
5. Move the app to the Trash: drag `fast-ios` from Applications (or
   `~/Applications`) to the Trash.
6. Delete what fast-ios saved:

   ```bash
   rm -rf ~/Library/Application\ Support/fast-ios ~/Library/Caches/fast-ios ~/Library/Logs/fast-ios.log
   ```

   That is the state folder (light sets, leases, what self-repair learned),
   the compiled screen-tree reader and the app cache, and the helper's log. Do this after
   step 1: the helper writes to the log while it runs.
7. Delete the app's settings:

   ```bash
   defaults delete dev.fast-ios.app
   ```

   It answers "Domain 'dev.fast-ios.app' not found" if the app never saved
   any; that is fine.

Left behind on purpose: each simulator's
`/private/var/tmp/com.apple.CoreSimulator.SimDevice.<UDID>/disabled.plist`
belongs to CoreSimulator, and after `fast-ios off` it holds no entries
fast-ios turned off. Screenshots and other temporary files are in the macOS
temporary folder, which macOS clears by itself.
