#!/usr/bin/env bash
# Real screen captures of the Phase 1 chrome under an accessibility display setting.
# 1. Turn the setting on yourself: System Settings ▸ Accessibility ▸ Display ▸ Reduce transparency
#    (or Increase contrast). Jit never changes system settings.
# 2. Run: scripts/testing/capture-accessibility.sh <suffix>   e.g. reducetransparency | increasecontrast
# Writes docs/phases/01-shell-and-tabs/screenshots/{tabbar-default,workbench-normal,newtab-recents}-<suffix>-{light,dark}.png
# using throwaway repositories and state (never your own Jit state). Needs Screen Recording permission for the
# terminal and a debug build (scripts/build/build-app.sh debug).
set -euo pipefail
SUFFIX="${1:?usage: capture-accessibility.sh <suffix>}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# Refuse to produce mislabelled captures: the matching system setting must be on right now.
case "$SUFFIX" in
    reducetransparency) FLAG=accessibilityDisplayShouldReduceTransparency ;;
    increasecontrast) FLAG=accessibilityDisplayShouldIncreaseContrast ;;
    *) FLAG="" ;;
esac
if [[ -n "$FLAG" ]]; then
    STATE="$(swift -e "import AppKit; print(NSWorkspace.shared.$FLAG)" 2>/dev/null || echo unknown)"
    if [[ "$STATE" != "true" ]]; then
        echo "error: macOS reports $FLAG = $STATE. Turn the setting on in System Settings ▸ Accessibility ▸ Display first." >&2
        exit 1
    fi
fi
OUT="$ROOT/docs/phases/01-shell-and-tabs/screenshots"
WORK="$(mktemp -d -t jit-a11y)"
trap 'rm -rf "$WORK"' EXIT
export GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Fixture GIT_AUTHOR_EMAIL=fixture@example.com GIT_COMMITTER_NAME=Fixture GIT_COMMITTER_EMAIL=fixture@example.com
printf '[init]\n\tdefaultBranch = main\n' > "$GIT_CONFIG_GLOBAL"
for name in alpha beta gamma; do
    mkdir -p "$WORK/$name" && git -C "$WORK/$name" init -q
    echo "$name" > "$WORK/$name/README.md" && git -C "$WORK/$name" add -A && git -C "$WORK/$name" commit -qm init
done
echo change >> "$WORK/alpha/README.md"; echo new > "$WORK/alpha/new.txt"
python3 - "$WORK" <<'PY'
import json, os, sys, uuid
w = sys.argv[1]
tabs = [{"id": str(uuid.uuid4()).upper(), "kind": "repository", "path": f"{w}/{n}", "titleCache": n,
         "sidebarCollapsed": False, "inspectorCollapsed": False, "ui": {}} for n in ("alpha", "beta", "gamma")]
profile = {"id": str(uuid.uuid4()).upper(), "displayName": "Work", "colorIndex": 1,
           "author": {"name": "Ada Lovelace", "email": "ada@example.com"}}
recents = [{"path": f"{w}/{n}", "name": n, "lastOpened": "2026-11-08T10:00:00Z", "lastBranch": "main"} for n in ("alpha", "beta", "gamma")]
for state, session in (("repo", {"version": 1, "tabs": tabs, "activeTabID": tabs[0]["id"]}),
                       ("newtab", {"version": 1, "tabs": [{"id": str(uuid.uuid4()).upper(), "kind": "newTab", "titleCache": "New Tab",
                                    "sidebarCollapsed": False, "inspectorCollapsed": False, "ui": {}}]})):
    d = f"{w}/state-{state}"; os.makedirs(d)
    json.dump(session, open(f"{d}/session.json", "w"))
    json.dump({"version": 1, "profiles": [profile], "activeProfileID": profile["id"]}, open(f"{d}/profiles.json", "w"))
    json.dump({"version": 1, "entries": recents}, open(f"{d}/recents.json", "w"))
PY
shot() {  # state name appearance
    rm -rf "$WORK/run" && cp -R "$WORK/state-$1" "$WORK/run"
    JIT_APP_SUPPORT="$WORK/run" JIT_SCREENSHOT_SETTLE=3 "$ROOT/scripts/testing/screenshot.sh" "$3" "$OUT/$2-$SUFFIX-$3.png"
}
for appearance in light dark; do
    shot repo tabbar-default "$appearance"
    shot repo workbench-normal "$appearance"
    shot newtab newtab-recents "$appearance"
done
