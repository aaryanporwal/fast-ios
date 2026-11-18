# Install

Back to the [README](../README.md).

You need macOS 15 or newer, an iOS 18.5 or newer simulator runtime, and, to
compile from source, Swift 6.3 or newer (Xcode 26.6 or newer). CI compiles
and tests every pull request on Xcode 26.6 (Swift 6.3), and again on any
newer Xcode the GitHub runner image gains.

**One line in Terminal (recommended).** Paste this; it installs the menu-bar
app and the `fast-ios` command with no security warning:

```bash
curl -fsSL https://raw.githubusercontent.com/aaryanporwal/fast-ios/main/packaging/install.sh | bash
```

What [`packaging/install.sh`](../packaging/install.sh) does:

1. Downloads the latest release zip of `fast-ios.app` from GitHub with `curl`.
   macOS does not mark files fetched with `curl` as downloaded, so it shows no
   "Not Opened" warning. The script never removes that mark from anything.
2. Puts `fast-ios.app` in `/Applications` (or `~/Applications` if that needs a
   password), replacing an older copy by rename.
3. Links the `fast-ios` command into the first writable folder of
   `/opt/homebrew/bin`, `/usr/local/bin` and `~/.local/bin`, unless another
   install of the command is already there.
4. Restarts fast-ios's background helper if it runs from that link, so it
   picks up the new version.
5. Opens the app, which walks you through setup.

It asks for no password. `FASTIOS_FROM_SOURCE=1` builds the app from source
with Xcode instead of downloading it.

**Homebrew, for developers.** Builds fast-ios from source on your Mac, also with
no warning, and installs both the command and the menu-bar app:

```bash
brew install aaryanporwal/fast-ios/fast-ios
```

The app is at `$(brew --prefix)/opt/fast-ios/fast-ios.app`. `brew upgrade
fast-ios` updates both.

**Or download the app.** Open the DMG from the
[latest release](https://github.com/aaryanporwal/fast-ios/releases/latest) and
drag fast-ios to Applications. fast-ios is free and not notarized with Apple,
so macOS blocks the first open; the source is all here to read. The first
time, macOS shows **“fast-ios” Not Opened**, with the buttons Move to Trash and
Done:

1. Click **Done**. Never Move to Trash: that deletes the app.
2. Open System Settings, then Privacy & Security.
3. Scroll down to Security. Next to "“fast-ios” was blocked to protect your
   Mac.", click **Open Anyway**, then confirm.

<!-- SCREENSHOT SLOT: site/public/open-anyway.webp (that Security row, macOS 27.0.1). -->

If that is more than you want, use the one-line install above instead.

To remove fast-ios: [uninstall.md](uninstall.md).
