#!/bin/bash
set -euo pipefail
project=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
skill="$project/mac-window-snap"
bash -n "$skill/scripts/window-snap.sh"
source "$skill/scripts/window-snap.sh"

for value in 0.30 0.65 .8 0.95; do valid_fraction "$value" || die "Rejected valid fraction $value"; done
for value in 0.2 1 NaN inf 0.66junk '-0.6' ''; do
    if valid_fraction "$value"; then die "Accepted invalid fraction $value"; fi
done

mkdir -p "$project/.build"
fixture=$(mktemp -d "$project/.build/check.XXXXXX")
/usr/bin/xcrun swiftc "$skill/assets/Model.swift" "$project/tests/main.swift" -o "$fixture/geometry-check"
"$fixture/geometry-check"
/usr/bin/xcrun swiftc -D TESTING -parse-as-library "$skill/assets/Model.swift" "$skill/assets/main.swift" "$project/tests/RuntimeChecks.swift" -o "$fixture/runtime-check"
"$fixture/runtime-check"
for selection in com.apple.Terminal com.mitchellh.ghostty com.termius-dmg.mac com.apple.Terminal,com.mitchellh.ghostty com.mitchellh.ghostty,com.apple.Terminal com.apple.Terminal,com.termius-dmg.mac com.mitchellh.ghostty,com.termius-dmg.mac com.apple.Terminal,com.mitchellh.ghostty,com.termius-dmg.mac com.termius-dmg.mac,com.mitchellh.ghostty,com.apple.Terminal none; do apps_json "$selection" >/dev/null || die "Rejected app selection $selection"; done
for selection in unknown com.apple.Terminal,com.apple.Terminal com.mitchellh.ghostty,other com.termius-dmg.mac,com.termius-dmg.mac none,com.termius-dmg.mac ',com.termius-dmg.mac' 'com.termius-dmg.mac,' 'com.apple.Terminal,,com.termius-dmg.mac' ''; do
    if apps_json "$selection"; then die "Accepted invalid app selection $selection"; fi
done
[ "$(apps_json com.termius-dmg.mac,com.mitchellh.ghostty,com.apple.Terminal)" = '["com.termius-dmg.mac","com.mitchellh.ghostty","com.apple.Terminal"]' ] || die 'Application selection is not canonical.'

# Exercise real plist and recoverable-uninstall operations in an isolated fixture.
# HOME is not changed, no user app is launched, and no real launch agent is touched.
user_home="$fixture/user with spaces & quotes'"
app="$user_home/Applications/$name"
support="$user_home/Library/Application Support/MacWindowSnap"
agent="$user_home/Library/LaunchAgents/$label.plist"
receipt="$support/receipt.plist"
service="gui/$(id -u)/local.mac-window-snap.test.$$"
mkdir -p "$app" "$support" "$(dirname "$agent")" "$user_home/.Trash"
printf 'fixture\n' > "$app/preserved.txt"
/usr/bin/plutil -create xml1 "$receipt"
/usr/bin/plutil -insert label -string "$label" "$receipt"
create_config "$support/settings.plist" .65
awk -v value="$(read_key "$support/settings.plist" fraction)" 'BEGIN { exit !(value > 0.64999 && value < 0.65001) }' || die 'Fraction did not round-trip.'
/usr/bin/plutil -create xml1 "$agent"
/usr/bin/plutil -insert ProgramArguments -json '[]' "$agent"
/usr/bin/plutil -insert ProgramArguments.0 -string "$app/Contents/MacOS/MacWindowSnap" "$agent"
[ "$(read_key "$agent" ProgramArguments.0)" = "$app/Contents/MacOS/MacWindowSnap" ] || die 'Path escaping failed.'
check_owned
uninstall > "$fixture/uninstall-report.txt"
[ ! -e "$app" ] && [ ! -e "$support" ] && [ ! -e "$agent" ] || die 'Uninstall left managed targets behind.'
trash=$(find "$user_home/.Trash" -mindepth 1 -maxdepth 1 -type d -print)
[ -f "$trash/$name/preserved.txt" ] && [ -f "$trash/MacWindowSnap/receipt.plist" ] || die 'Uninstall did not preserve the app and settings.'

# An unowned installation must not be accepted for uninstall or replacement.
if (check_owned) > "$fixture/refusal.txt" 2>&1; then die 'Accepted an unowned installation.'; fi

# Simulate an interrupted upgrade and verify the exact prior app/agent are restored.
mkdir -p "$app" "$support" "$(dirname "$agent")"
printf 'original\n' > "$app/original.txt"
printf 'original-agent\n' > "$agent"
backup=$(mktemp -d "$fixture/rollback.XXXXXX")
mv "$app" "$backup/$name"
mv "$agent" "$backup/agent.plist"
mkdir "$app"
printf 'replacement\n' > "$app/replacement.txt"
printf 'replacement-agent\n' > "$agent"
if (
    unload() { :; }
    transaction=active; was_loaded=no
    new_app_placed=yes; new_agent_placed=yes; old_app_moved=yes; old_agent_moved=yes
    trap rollback EXIT
    exit 17
); then die 'Expected rollback failure exit status.'; else
    result=$?
    [ "$result" -eq 17 ] || die "Rollback changed exit status to $result"
fi
[ -f "$app/original.txt" ] && [ "$(cat "$agent")" = original-agent ] || die 'Rollback did not restore originals.'
[ -f "$backup/failed-$name/replacement.txt" ] || die 'Rollback discarded the failed replacement.'

printf 'Shell: fraction validation, escaped paths, ownership refusal, Trash uninstall and upgrade rollback passed.\nFixtures retained at %s\n' "$fixture"
