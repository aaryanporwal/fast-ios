#!/bin/bash
# fast-ios installer. Paste into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/aaryanporwal/fast-ios/main/packaging/install.sh | bash
#
# What it does, in order:
#   1. Checks this is macOS 15 or newer.
#   2. Downloads the latest release zip of fast-ios.app from GitHub with curl
#      (or, with FASTIOS_FROM_SOURCE=1, builds it from source with Xcode).
#      Files curl downloads are not marked as downloaded (no
#      com.apple.quarantine), so macOS does not show its "Not Opened" warning.
#      This script never removes that mark from anything.
#   3. Puts fast-ios.app in /Applications (or ~/Applications if /Applications
#      is not writable without a password), replacing an older copy by rename.
#   4. Links the `fast-ios` command into the first writable folder of
#      /opt/homebrew/bin, /usr/local/bin, ~/.local/bin (a link to the copy
#      inside the app), unless another install of the command is already there.
#   5. If fast-ios's background helper is running from that link, restarts it
#      on the new version.
#   6. Opens the app, which starts its short setup.
# It asks for no password and changes nothing outside those folders.
#
# Environment:
#   FASTIOS_FROM_SOURCE=1  build from source instead of downloading (needs Xcode)
#   FASTIOS_REF            branch or tag to build from source (default: main)
#   FASTIOS_SRC            build this local checkout (implies from source)
#   FASTIOS_ZIP_URL        download this zip instead of the latest release
#   FASTIOS_APP_DIR        where fast-ios.app goes (default: /Applications or ~/Applications)
#   FASTIOS_BIN_DIR        where the `fast-ios` link goes (default: see step 4)
#   FASTIOS_OPEN=0         do not open the app at the end
set -euo pipefail

REPO="aaryanporwal/fast-ios"
APP_NAME="fast-ios.app"
AGENT_LABEL="dev.fast-ios.auto"

say() { printf 'fast-ios: %s\n' "$*"; }
die() { printf 'fast-ios: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = "Darwin" ] || die "macOS only."
major=$(sw_vers -productVersion | cut -d. -f1)
[ "$major" -ge 15 ] || die "needs macOS 15 or newer (found $(sw_vers -productVersion))."

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# --- 2. Get fast-ios.app into $work ---------------------------------------
if [ -n "${FASTIOS_SRC:-}" ] || [ "${FASTIOS_FROM_SOURCE:-0}" = "1" ]; then
  command -v swift >/dev/null || die "Swift not found. Install Xcode first, or drop FASTIOS_FROM_SOURCE to download the app."
  # The minimum is Swift 6.3 (Xcode 26.6), as in Package.swift.
  swift_version=$(swift --version 2>/dev/null | sed -n 's/.*Swift version \([0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
  swift_major=${swift_version%%.*}; swift_minor=${swift_version#*.}
  if [ -z "$swift_version" ] || [ "$swift_major" -lt 6 ] || { [ "$swift_major" -eq 6 ] && [ "$swift_minor" -lt 3 ]; }; then
    die "compiling fast-ios needs Swift 6.3 or newer (Xcode 26.6 or newer); found ${swift_version:-none}. Update Xcode, or drop FASTIOS_FROM_SOURCE to download the app."
  fi
  if [ -n "${FASTIOS_SRC:-}" ]; then
    src="$FASTIOS_SRC"
  else
    command -v git >/dev/null || die "git not found."
    say "cloning https://github.com/$REPO (${FASTIOS_REF:-main})"
    git clone --quiet --depth 1 --branch "${FASTIOS_REF:-main}" "https://github.com/$REPO.git" "$work/src"
    src="$work/src"
  fi
  say "compiling (the first time takes a minute or two)"
  (cd "$src" && ARCHS="$(uname -m)" scripts/bundle-app.sh >/dev/null)
  ditto "$src/.build/$APP_NAME" "$work/$APP_NAME"
else
  url="${FASTIOS_ZIP_URL:-}"
  if [ -z "$url" ]; then
    tag=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
    [ -n "$tag" ] || die "could not find the latest release on GitHub. Try again, or use Homebrew: brew install $REPO/fast-ios"
    url="https://github.com/$REPO/releases/download/$tag/fast-ios-${tag#v}.zip"
  fi
  say "downloading $url"
  curl -fsSL -o "$work/fast-ios.zip" "$url" || die "download failed: $url"
  ditto -x -k "$work/fast-ios.zip" "$work"
fi
[ -d "$work/$APP_NAME" ] || die "no $APP_NAME in the download."
codesign --verify --strict "$work/$APP_NAME" 2>/dev/null || die "$APP_NAME failed its code signature check; not installing it."

# --- 3. Install the app by rename -------------------------------------------
if [ -n "${FASTIOS_APP_DIR:-}" ]; then
  app_dir="$FASTIOS_APP_DIR"
elif [ -w /Applications ]; then
  app_dir=/Applications
else
  app_dir="$HOME/Applications"
fi
mkdir -p "$app_dir"
app="$app_dir/$APP_NAME"

# Quit a running copy of the menu-bar app; it is reopened at the end.
pkill -f "$app/Contents/MacOS/FastIOSBar" 2>/dev/null || true

# Never copy over files in place: a binary rewritten in place while a process
# runs it is killed on its next launch (SIGKILL, exit 137) on Apple silicon.
# Stage next to the target, then swap by rename, so every file is new.
staged="$app_dir/.fast-ios.app.new.$$"
old="$app_dir/.fast-ios.app.old.$$"
rm -rf "$staged" "$old"
ditto "$work/$APP_NAME" "$staged"
if [ -e "$app" ]; then mv "$app" "$old"; fi
mv "$staged" "$app"
rm -rf "$old"
say "installed $app"

# --- 4. Link the command ----------------------------------------------------
cli="$app/Contents/MacOS/fast-ios"
link=""
if [ -n "${FASTIOS_BIN_DIR:-}" ]; then
  mkdir -p "$FASTIOS_BIN_DIR"
  dirs=("$FASTIOS_BIN_DIR")
else
  dirs=(/opt/homebrew/bin /usr/local/bin "$HOME/.local/bin")
fi
for d in "${dirs[@]}"; do
  case "$d" in "$HOME"/*) mkdir -p "$d" ;; esac
  [ -d "$d" ] && [ -w "$d" ] || continue
  candidate="$d/fast-ios"
  if [ -e "$candidate" ] || [ -L "$candidate" ]; then
    target=$(readlink "$candidate" 2>/dev/null || true)
    case "$target" in
      *".app/Contents/MacOS/fast-ios") ;;  # a link to an app copy: ours to update
      *) say "leaving $candidate alone: another install of the command (Homebrew or a copy) is there."
         link="$candidate"; break ;;
    esac
  fi
  # A new link under a temporary name, then rename over the old one.
  ln -s "$cli" "$candidate.new.$$"
  mv -f "$candidate.new.$$" "$candidate"
  link="$candidate"
  say "linked $candidate -> $cli"
  break
done
[ -n "$link" ] || say "no writable folder on your PATH; run the command as $cli"

# --- 5. Restart the background helper if it runs from this link ---------------
agent_plist="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"
if [ -n "$link" ] && [ -f "$agent_plist" ]; then
  program=$(plutil -extract ProgramArguments.0 raw -o - "$agent_plist" 2>/dev/null || true)
  if [ "$program" = "$link" ] || [ "$program" = "$cli" ]; then
    launchctl kickstart -k "gui/$(id -u)/$AGENT_LABEL" 2>/dev/null && say "restarted the background helper on the new version" || true
  fi
fi

case ":$PATH:" in
  *":$(dirname "${link:-/nonexistent/x}"):"*) ;;
  *) [ -n "$link" ] && say "add $(dirname "$link") to your PATH to type fast-ios in any Terminal" ;;
esac

# --- 6. Open the app (its setup starts on first launch) ------------------------
if [ "${FASTIOS_OPEN:-1}" != "0" ]; then
  open "$app"
  say "opened fast-ios; it lives in the menu bar"
fi
say "done. Try: fast-ios"
