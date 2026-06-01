#!/bin/sh
# gwt installer — double-click me.
#
# macOS opens *.command files in Terminal when double-clicked, so this installs
# gwt without touching the command line:
#   1. checks that zsh is installed (bails with a message if not),
#   2. copies gwt.zsh into ~/.zsh/gwt/ (with a logs/ dir alongside),
#   3. adds a `source` line to ~/.my-zshrc (or ~/.zshrc as fallback), exactly
#      once — removing any duplicate from the other file,
#   4. loads it so `gwt` works in new terminals.

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
SRC="$SCRIPT_DIR/gwt.zsh"
DEST_DIR="$HOME/.zsh/gwt"
DEST="$DEST_DIR/gwt.zsh"
LINE='source "$HOME/.zsh/gwt/gwt.zsh"'

printf '\n  gwt installer\n  ─────────────────────────────\n\n'

pause_and_exit() {
  status="$1"
  if [ "$status" -eq 0 ] && [ "$TERM_PROGRAM" = "Apple_Terminal" ]; then
    # Post a desktop notification NOW, while we're still a foreground process in the
    # GUI session — that's when `display notification` reliably shows. The window is
    # about to close, so this banner is how you know it finished.
    /usr/bin/osascript -e 'display notification "Installed. Open a new terminal, then run: gwt -h" with title "gwt installer" sound name "Glass"' >/dev/null 2>&1
    printf '\n  Installed — closing this window.\n'
    # After a short beat: close THIS window (matched by the script path, so only the
    # double-click window is targeted). If it was Terminal's ONLY window, quit
    # Terminal so it does not linger in the Dock; if you have other Terminal windows
    # open, those are left alone and Terminal keeps running.
    ( sleep 1
      /usr/bin/osascript \
        -e 'tell application "Terminal"' \
        -e 'if (count of windows) < 2 then' \
        -e '  quit' \
        -e 'else' \
        -e "  close (every window whose name contains \"$0\") saving no" \
        -e 'end if' \
        -e 'end tell'
    ) >/dev/null 2>&1 &
    exit 0
  fi
  printf '\n  Press Return to close this window.'
  read _dummy
  exit "$status"
}

# 1. zsh must be installed -------------------------------------------------
if ! command -v zsh >/dev/null 2>&1; then
  printf '  ✗ zsh is not installed on this system.\n\n'
  printf '    gwt is a zsh tool and cannot run without it.\n'
  printf '    macOS normally ships with zsh; if it is missing, install it\n'
  printf '    (e.g. "brew install zsh", or apt/dnf on Linux) and run this again.\n'
  pause_and_exit 1
fi
printf '  ✓ zsh found: %s\n' "$(command -v zsh)"

# 2. locate gwt.zsh next to this installer ---------------------------------
if [ ! -f "$SRC" ]; then
  printf '  ✗ Could not find gwt.zsh next to this installer:\n      %s\n' "$SRC"
  printf '    Keep install.command in the same folder as gwt.zsh.\n'
  pause_and_exit 1
fi

# 3. copy into ~/.zsh/gwt ---------------------------------------------------
# Migrate any older loose install (~/.zsh/gwt.zsh + ~/.zsh/gwt-examples) into the
# new self-contained ~/.zsh/gwt/ folder, so re-running leaves no stragglers.
rm -f  "$HOME/.zsh/gwt.zsh"
rm -rf "$HOME/.zsh/gwt-examples"

mkdir -p "$DEST_DIR/logs"
cp "$SRC" "$DEST"
printf '  ✓ Installed gwt.zsh → %s\n' "$DEST"

# The example config is NOT installed. Nothing reads it — gwt scaffolds every
# project's gwt.conf from the template inside gwt.zsh itself — so an installed
# copy only sits there going stale. Read it in the repo, or run `gwt config edit`
# to get the real thing. Remove any copy an older installer left behind.
if [ -d "$DEST_DIR/gwt-examples" ]; then
  rm -rf "$DEST_DIR/gwt-examples"
  printf '  ✓ Removed stale example configs from %s\n' "$DEST_DIR/gwt-examples"
fi

# 4. reference it from the right rc file, exactly once ---------------------
# Prefer ~/.my-zshrc (the user's real config); fall back to ~/.zshrc if absent.
if [ -f "$HOME/.my-zshrc" ]; then
  RC="$HOME/.my-zshrc"
  OTHER="$HOME/.zshrc"
else
  RC="$HOME/.zshrc"
  OTHER="$HOME/.my-zshrc"
fi

# De-duplicate: strip any gwt source line (and an installer-added comment) from
# the OTHER rc file, so gwt is sourced from exactly one place.
# The pattern matches both the old loose line (~/.zsh/gwt.zsh) and the new
# nested one (~/.zsh/gwt/gwt.zsh), so a re-run cleans up either form.
if [ -f "$OTHER" ] && grep -q '\.zsh/.*gwt\.zsh' "$OTHER" 2>/dev/null; then
  tmp="$OTHER.gwt-tmp.$$"
  grep -v -e '\.zsh/.*gwt\.zsh' -e '# gwt — git worktree manager' "$OTHER" > "$tmp" && mv "$tmp" "$OTHER"
  printf '  ✓ Removed duplicate gwt source from ~/%s\n' "${OTHER#"$HOME"/}"
fi

# Ensure the chosen rc file sources gwt from the CURRENT path. If it already has
# the exact line, leave it; otherwise strip any old/stale gwt source line and
# append the fresh one — this migrates an old ~/.zsh/gwt.zsh reference in place.
touch "$RC"
if grep -qF "$LINE" "$RC" 2>/dev/null; then
  printf '  ✓ ~/%s already sources gwt\n' "${RC#"$HOME"/}"
else
  if grep -q '\.zsh/.*gwt\.zsh' "$RC" 2>/dev/null; then
    tmp="$RC.gwt-tmp.$$"
    grep -v -e '\.zsh/.*gwt\.zsh' -e '# gwt — git worktree manager' "$RC" > "$tmp" && mv "$tmp" "$RC"
  fi
  printf '\n# gwt — git worktree manager\n%s\n' "$LINE" >> "$RC"
  printf '  ✓ Added source line to ~/%s\n' "${RC#"$HOME"/}"
fi

# 5. load it now + verify --------------------------------------------------
# A fresh interactive zsh sources the user's full startup chain (~/.zshrc, which
# pulls in ~/.my-zshrc), so this mirrors what a new terminal will see.
if zsh -ic 'typeset -f gwt >/dev/null' >/dev/null 2>&1; then
  printf '  ✓ gwt loads cleanly\n'
else
  printf '  ! Could not auto-verify — open a NEW terminal and run: gwt -h\n'
fi

printf '\n  Done!  Open a new terminal (or run:  source ~/.zshrc), then try:\n\n'
printf '      gwt -h\n'
pause_and_exit 0
