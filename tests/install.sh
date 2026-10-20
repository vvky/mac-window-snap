#!/bin/bash
# Only launchctl is replaced; install still copies/verifies a real compiled app.
set -euo pipefail
project=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
skill="$project/mac-window-snap"
source "$skill/scripts/window-snap.sh"
fixture=$(mktemp -d "$project/.build/install-check.XXXXXX")
user_home="$fixture/desktop user & quotes'"
app="$user_home/Applications/$name"
support="$user_home/Library/Application Support/MacWindowSnap"
agent="$user_home/Library/LaunchAgents/$label.plist"
binary="$app/Contents/MacOS/MacWindowSnap"
receipt="$support/receipt.plist"
config="$support/settings.plist"
service="gui/$(id -u)/local.mac-window-snap.test.$$"
launchctl_cmd() {
    printf '%s\n' "$*" >> "$fixture/launchctl.txt"
    case "$1" in
        print) [ -f "$fixture/loaded" ] ;;
        bootstrap) printf 'loaded\n' > "$fixture/loaded" ;;
        bootout) mv "$fixture/loaded" "$fixture/unloaded-$(date +%s)-$$" ;;
        kickstart|kill) : ;;
        *) die 'Unexpected test launchctl command.' ;;
    esac
}

install --dry-run > "$fixture/plan.txt"
[ ! -e "$user_home" ] || die 'Dry run wrote installation files.'
install > "$fixture/first-install.txt"
[ -x "$binary" ] && [ -f "$receipt" ] && [ -f "$fixture/loaded" ] || die 'First installation failed.'
[ "$(read_key "$config" applications)" = 0 ] || die 'New installs must not manage applications implicitly.'
configure --apps org.example.Editor,com.apple.finder > "$fixture/generic-apps.txt"
[ "$(read_key "$config" applications.0)" = org.example.Editor ] || die 'Arbitrary bundle ID was rejected.'
unchanged=$(/usr/bin/shasum -a 256 "$config")
if (configure --font-size 14) > "$fixture/removed-option.txt" 2>&1; then die 'Removed font option was accepted.'; fi
[ "$unchanged" = "$(/usr/bin/shasum -a 256 "$config")" ] || die 'Removed option changed configuration.'
first_hash=$(/usr/bin/shasum -a 256 "$binary")
first_backups=$(find "$support/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)
configure --apps com.apple.Terminal,com.mitchellh.ghostty > "$fixture/enable-both.txt"
configure --fraction .72 > "$fixture/configure.txt"
[ "$(read_key "$config" applications)" = 2 ] || die 'Changing the fraction lost application selection.'
configure --apps com.mitchellh.ghostty > "$fixture/ghostty-only.txt"
[ "$(read_key "$config" applications.0)" = com.mitchellh.ghostty ] || die 'Ghostty-only configuration failed.'
awk -v value="$(read_key "$config" fraction)" 'BEGIN {exit !(value > 0.71999 && value < 0.72001)}' || die 'Changing applications lost the fraction.'
unchanged=$(/usr/bin/shasum -a 256 "$config")
if (configure --fraction .8 --apps com.apple.Terminal,unknown) > "$fixture/invalid-apps.txt" 2>&1; then die 'Invalid application selection was accepted.'; fi
[ "$unchanged" = "$(/usr/bin/shasum -a 256 "$config")" ] || die 'Invalid application selection changed configuration.'
configure --apps none > "$fixture/manage-none.txt"
[ "$(read_key "$config" applications)" = 0 ] || die 'No-app selection failed.'
# Upgrade a legacy configuration that had no application list.
/usr/bin/plutil -remove applications "$config"
configure --apps com.mitchellh.ghostty,com.apple.Terminal > "$fixture/legacy-selection.txt"
[ "$(read_key "$config" applications)" = 2 ] && [ "$(read_key "$config" applications.0)" = com.mitchellh.ghostty ] || die 'Legacy application selection migration failed.'
configure --apps com.termius-dmg.mac > "$fixture/termius-only.txt"
[ "$(read_key "$config" applications.0)" = com.termius-dmg.mac ] || die 'Termius-only configuration failed.'
configure --apps com.termius-dmg.mac,com.mitchellh.ghostty,com.apple.Terminal > "$fixture/three-applications.txt"
[ "$(read_key "$config" applications)" = 3 ] && [ "$(read_key "$config" applications.2)" = com.apple.Terminal ] || die 'Three-application configuration failed.'
install > "$fixture/reinstall.txt"
[ "$first_hash" = "$(/usr/bin/shasum -a 256 "$binary")" ] || die 'Reinstall changed binary identity.'
[ "$first_backups" = "$(find "$support/backups" -mindepth 1 -maxdepth 1 -type d | wc -l)" ] || die 'Reinstall unnecessarily created an upgrade backup.'
awk -v value="$(read_key "$config" fraction)" 'BEGIN {exit !(value > 0.71999 && value < 0.72001)}' || die 'Reinstall lost user settings.'
[ "$(read_key "$config" applications)" = 3 ] || die 'Reinstall lost the selected applications.'
[ "$(read_key "$agent" ProgramArguments.0)" = "$binary" ] || die 'Launch-agent executable path is wrong.'

# Fail one bootstrap during a real upgrade transaction. A separate shell keeps
# errexit enabled inside install, so its EXIT trap is exercised as in production.
export test_fixture="$fixture" test_home="$user_home" test_skill="$skill"
if /bin/bash <<'CHILD'
set -euo pipefail
source "$test_skill/scripts/window-snap.sh"
user_home=$test_home
app="$user_home/Applications/$name"
support="$user_home/Library/Application Support/MacWindowSnap"
agent="$user_home/Library/LaunchAgents/$label.plist"
binary="$app/Contents/MacOS/MacWindowSnap"
receipt="$support/receipt.plist"
config="$support/settings.plist"
service="gui/$(id -u)/local.mac-window-snap.fixture"
launchctl_cmd() {
    case "$1" in
        print) [ -f "$test_fixture/loaded" ] ;;
        bootout) mv "$test_fixture/loaded" "$test_fixture/unloaded-upgrade" ;;
        bootstrap)
            if [ ! -f "$test_fixture/failed-once" ]; then
                printf 'failed\n' > "$test_fixture/failed-once"
                return 19
            fi
            printf 'restored\n' > "$test_fixture/loaded" ;;
        *) : ;;
    esac
}
# Make the receipt differ without changing production sources or the signed app.
/usr/bin/plutil -replace sourceHash -string outdated "$receipt"
install
CHILD
then die 'Upgrade was expected to fail.'; else
    result=$?
    [ "$result" -eq 19 ] || die "Unexpected upgrade failure code: $result"
fi
[ "$first_hash" = "$(/usr/bin/shasum -a 256 "$binary")" ] || die 'Failed upgrade did not restore the original binary.'
[ -f "$fixture/loaded" ] || die 'Failed upgrade did not restore the prior loaded job.'
printf 'Install: dry run, staging, idempotence, application selection, config preservation and bootstrap-failure rollback passed.\nFixtures retained at %s\n' "$fixture"
