#!/bin/bash
# macOS ships Bash 3.2. No Homebrew, Python, Node, sudo, or shell-profile edits.
set -euo pipefail

script_dir=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
skill_dir=$(cd -P -- "$script_dir/.." && pwd)
label=local.mac-window-snap
name='Mac Window Snap.app'

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
launchctl_cmd() { /bin/launchctl "$@"; }
require_macos() {
    [ "$(uname -s)" = Darwin ] || die 'This skill requires a local macOS desktop.'
    [ "$(id -u)" != 0 ] || die 'Run as the signed-in user, without sudo.'
    [ "$(uname -r | cut -d . -f 1)" -ge 22 ] || die 'macOS 13 or newer is required.'
    user_home=$(cd -P -- "$HOME" && pwd)
    [ "$user_home" != / ] || die 'Cannot resolve a user home directory.'
    service="gui/$(id -u)/$label"
    app="$user_home/Applications/$name"
    support="$user_home/Library/Application Support/MacWindowSnap"
    agent="$user_home/Library/LaunchAgents/$label.plist"
    binary="$app/Contents/MacOS/MacWindowSnap"
    receipt="$support/receipt.plist"
    config="$support/settings.plist"
}

read_key() { /usr/bin/plutil -extract "$2" raw -o - "$1" 2>/dev/null; }
fingerprint() {
    { /usr/bin/shasum -a 256 "$skill_dir/assets/Model.swift" "$skill_dir/assets/main.swift" "$skill_dir/assets/Info.plist" "$skill_dir/LICENSE" | awk '{print $1}'; uname -m; } |
        /usr/bin/shasum -a 256 | awk '{print $1}'
}
check_owned() {
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || die 'No installation receipt. Refusing to overwrite or remove an unmanaged installation.'
    [ "$(read_key "$receipt" label)" = "$label" ] || die 'Unexpected installation receipt.'
    for path in "$app" "$support" "$agent"; do
        [ ! -L "$path" ] || die "Refusing a symbolic-link installation target: $path"
    done
}
check_parents() {
    local parent
    for parent in "$user_home/Applications" "$user_home/Library" "$user_home/Library/Application Support" "$user_home/Library/LaunchAgents"; do
        if [ -d "$parent" ]; then
            [ "$(cd -P -- "$parent" && pwd)" = "$parent" ] || die "Refusing a redirected installation directory: $parent"
        fi
    done
}
service_pid() { launchctl_cmd print "$service" 2>/dev/null | awk '$1 == "pid" && $2 == "=" {print $3; exit}' || true; }
unload() {
    if launchctl_cmd print "$service" >/dev/null 2>&1; then launchctl_cmd bootout "$service"; fi
}

build() {
    local hash directory executable compiler
    compiler=$(/usr/bin/xcrun --find swiftc 2>/dev/null) || die 'Install Apple Command Line Tools first (xcode-select --install), then retry.'
    hash=$(fingerprint)
    directory="$skill_dir/.build/$hash/$name"
    executable="$directory/Contents/MacOS/MacWindowSnap"
    if [ ! -x "$executable" ] || ! /usr/bin/codesign --verify --deep --strict "$directory" 2>/dev/null; then
        mkdir -p "$directory/Contents/MacOS" "$directory/Contents/Resources"
        cp "$skill_dir/assets/Info.plist" "$directory/Contents/Info.plist"
        cp "$skill_dir/LICENSE" "$directory/Contents/Resources/LICENSE"
        "$compiler" -O -parse-as-library -sdk "$(/usr/bin/xcrun --show-sdk-path)" -target "$(uname -m)-apple-macosx13.0" "$skill_dir/assets/Model.swift" "$skill_dir/assets/main.swift" -o "$executable" || return 1
        /usr/bin/codesign --force --sign - --identifier "$label" "$directory" || return 1
        /usr/bin/codesign --verify --deep --strict "$directory" || return 1
    fi
    printf '%s\n' "$directory"
}

create_config() {
    local output=$1 fraction=$2
    /usr/bin/plutil -create xml1 "$output"
    /usr/bin/plutil -insert fraction -float "$fraction" "$output"
    /usr/bin/plutil -insert applications -json '[]' "$output"
}
valid_fraction() { awk -v value="$1" 'BEGIN { exit !(value ~ /^(0[.][0-9]+|[.][0-9]+)$/ && value >= 0.3 && value <= 0.95) }'; }
apps_json() {
    printf '%s\n' "$1" | awk '
    NR != 1 { exit 1 }
    {
        if ($0 == "none") { print "[]"; next }
        count = split($0, selected, ",")
        output = "["; separator = ""
        for (i = 1; i <= count; i++) {
            item = selected[i]
            if (item !~ /^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$/ || seen[item]++) exit 1
            output = output separator "\"" item "\""; separator = ","
        }
        if (!count) exit 1
        print output "]"
    }'
}

# Installation rollback preserves every displaced file; nothing is permanently deleted.
rollback() {
    local result=$?
    trap - EXIT
    if [ "$result" -ne 0 ] && [ "$transaction" = active ]; then
        printf 'Install failed; restoring the prior installation from %s\n' "$backup" >&2
        unload || true
        if [ "$new_app_placed" = yes ]; then mv "$app" "$backup/failed-$name"; fi
        if [ "$new_agent_placed" = yes ]; then mv "$agent" "$backup/failed-agent.plist"; fi
        if [ "$old_app_moved" = yes ]; then mv "$backup/$name" "$app"; fi
        if [ "$old_agent_moved" = yes ]; then mv "$backup/agent.plist" "$agent"; fi
        if [ -f "$backup/receipt.plist" ]; then cp "$backup/receipt.plist" "$receipt"; fi
        if [ "$was_loaded" = yes ] && [ -f "$agent" ]; then launchctl_cmd bootstrap "gui/$(id -u)" "$agent" || true; fi
    fi
    exit "$result"
}

install() {
    local dry=no built hash stage staged_agent backup transaction=idle was_loaded=no
    local new_app_placed=no new_agent_placed=no old_app_moved=no old_agent_moved=no
    if [ "${1:-}" = --dry-run ]; then dry=yes; shift; fi
    [ "$#" -eq 0 ] || die 'Usage: window-snap.sh install [--dry-run]'
    check_parents
    # Old startup files must be archived before installing under the new identity.
    if [ -e "$user_home/Library/LaunchAgents/local.terminal.windowhelper.plist" ] ||
       [ -e "$user_home/Applications/Terminal Window Helper.app" ]; then
        die 'Legacy Terminal Window Helper installation found. Follow references/troubleshooting.md (旧名称迁移) before installing Mac Window Snap.'
    fi
    for path in "$app" "$support" "$agent"; do [ ! -L "$path" ] || die "Refusing symbolic link: $path"; done
    if [ -e "$app" ] || [ -e "$agent" ] || [ -e "$support" ]; then check_owned; fi
    if [ "$dry" = yes ]; then
        printf 'Would install:\n  app: %s\n  launch agent: %s\n  config: %s\nDefaults: fraction 0.75, no applications selected. Theme and font stay as they are. No changes made.\n' "$app" "$agent" "$config"
        return
    fi
    hash=$(fingerprint)
    if [ -f "$receipt" ] && [ "$(read_key "$receipt" sourceHash)" = "$hash" ] &&
       [ -x "$binary" ] && /usr/bin/codesign --verify --deep --strict "$app" 2>/dev/null; then
        if ! launchctl_cmd print "$service" >/dev/null 2>&1; then launchctl_cmd bootstrap "gui/$(id -u)" "$agent"; fi
        launchctl_cmd kickstart "$service"
        printf 'Same version already installed; reused the existing binary and permission identity.\n'
        return
    fi
    built=$(build) || die 'Build failed. The installed app was not changed.'
    mkdir -p "$user_home/Applications" "$user_home/Library/LaunchAgents" "$support/backups"
    backup=$(mktemp -d "$support/backups/install.XXXXXX")
    stage="$backup/new-$name"
    /usr/bin/ditto "$built" "$stage"
    /usr/bin/codesign --verify --deep --strict "$stage"
    if [ ! -f "$config" ]; then create_config "$config" 0.75; fi
    staged_agent="$backup/new-agent.plist"
    /usr/bin/plutil -create xml1 "$staged_agent"
    /usr/bin/plutil -insert Label -string "$label" "$staged_agent"
    /usr/bin/plutil -insert ProgramArguments -json '[]' "$staged_agent"
    /usr/bin/plutil -insert ProgramArguments.0 -string "$binary" "$staged_agent"
    /usr/bin/plutil -insert RunAtLoad -bool YES "$staged_agent"
    /usr/bin/plutil -insert KeepAlive -bool YES "$staged_agent"
    /usr/bin/plutil -insert ThrottleInterval -integer 10 "$staged_agent"
    /usr/bin/plutil -insert StandardErrorPath -string "$support/helper.log" "$staged_agent"
    /usr/bin/plutil -lint "$staged_agent" >/dev/null
    if [ -f "$receipt" ]; then cp "$receipt" "$backup/receipt.plist"; fi
    if launchctl_cmd print "$service" >/dev/null 2>&1; then was_loaded=yes; fi
    trap rollback EXIT
    unload
    transaction=active
    if [ -e "$app" ]; then mv "$app" "$backup/$name"; old_app_moved=yes; fi
    if [ -e "$agent" ]; then mv "$agent" "$backup/agent.plist"; old_agent_moved=yes; fi
    mv "$stage" "$app"
    new_app_placed=yes
    mv "$staged_agent" "$agent"
    new_agent_placed=yes
    launchctl_cmd bootstrap "gui/$(id -u)" "$agent"
    local next_receipt="$backup/new-receipt.plist"
    /usr/bin/plutil -create xml1 "$next_receipt"
    /usr/bin/plutil -insert label -string "$label" "$next_receipt"
    /usr/bin/plutil -insert sourceHash -string "$hash" "$next_receipt"
    mv "$next_receipt" "$receipt"
    transaction=done
    trap - EXIT
    printf 'Installed. Backup: %s\nNext: run status; if permission is missing, run permissions.\n' "$backup"
}

configure() {
    check_owned
    local fraction='' apps='' selection='' next
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --fraction) [ "$#" -ge 2 ] && [ -n "$2" ] || die 'Missing fraction.'; fraction=$2; shift 2 ;;
            --apps) [ "$#" -ge 2 ] && [ -n "$2" ] || die 'Missing application selection.'; apps=$2; shift 2 ;;
            *) die "Unknown configure option: $1" ;;
        esac
    done
    [ -n "$fraction$apps" ] || die 'Usage: configure [--apps com.apple.finder,com.apple.Safari] [--fraction 0.75]'
    if [ -n "$apps" ]; then selection=$(apps_json "$apps") || die 'Apps must be unique comma-separated bundle identifiers, or none.'; fi
    if [ -n "$fraction" ]; then valid_fraction "$fraction" || die 'Fraction must be between 0.30 and 0.95.'; fi
    if [ -n "$fraction$apps" ]; then
        next=$(mktemp "$support/settings.XXXXXX")
        cp "$config" "$next"
        if [ -n "$fraction" ]; then /usr/bin/plutil -replace fraction -float "$fraction" "$next"; fi
        if [ -n "$apps" ]; then
            if /usr/bin/plutil -type applications "$next" >/dev/null 2>&1; then
                /usr/bin/plutil -replace applications -json "$selection" "$next"
            else /usr/bin/plutil -insert applications -json "$selection" "$next"; fi
        fi
        mv "$next" "$config"
        if [ -n "$fraction" ]; then printf 'Window width and height fraction: %s\n' "$fraction"; fi
        if [ -n "$apps" ]; then printf 'Managed applications: %s\n' "$apps"; fi
        if launchctl_cmd print "$service" >/dev/null 2>&1; then launchctl_cmd kill SIGHUP "$service"; fi
    fi

}

status() {
    local pid recorded
    pid=$(service_pid)
    if [ -z "$pid" ]; then printf 'Helper is not running.\n'; return 3; fi
    [ -f "$support/status.plist" ] || { printf 'Helper is starting; status not available yet.\n'; return 3; }
    recorded=$(read_key "$support/status.plist" pid)
    [ "$recorded" = "$pid" ] || { printf 'Stale status from a previous process; retry shortly.\n'; return 3; }
    /usr/bin/plutil -convert json -o - "$support/status.plist"
    printf '\n'
    if [ "$(read_key "$support/status.plist" managedApplications)" = 0 ]; then
        [ "$(read_key "$support/status.plist" error)" = '' ] || return 3
        return 0
    fi
    [ "$(read_key "$support/status.plist" trusted)" = true ] || return 2
    [ "$(read_key "$support/status.plist" error)" = '' ] || return 3
}

uninstall() {
    check_owned
    check_parents
    local trash target
    trash="$user_home/.Trash"
    [ -d "$trash" ] && [ ! -L "$trash" ] && [ -w "$trash" ] || die 'User Trash is unavailable; refusing permanent deletion.'
    # Each source is an exact, owned installation path; never use globs or broad roots.
    for path in "$app" "$support" "$agent"; do [ -e "$path" ] || die "Missing uninstall target: $path"; done
    target="$trash/MacWindowSnap-$(date +%Y%m%d-%H%M%S)-$$"
    [ ! -e "$target" ] || die "Trash destination already exists: $target"
    unload
    mkdir "$target"
    mv "$app" "$target/$name" || die "Move failed. Stop and recover from $target"
    mv "$agent" "$target/$label.plist" || die "Move failed. Stop and recover from $target"
    mv "$support" "$target/MacWindowSnap" || die "Move failed. Stop and recover from $target"
    printf 'Moved to Trash (no permanent deletion):\n%s -> %s\n%s -> %s\n%s -> %s\n' "$app" "$target/$name" "$agent" "$target/$label.plist" "$support" "$target/MacWindowSnap"
    printf 'Restore these three items to their original paths, then run:\n  launchctl bootstrap gui/%s %q\n' "$(id -u)" "$agent"
}

usage() {
    cat <<'HELP'
window-snap.sh <command>
  build                          Compile locally; do not install or request permission.
  install [--dry-run]             Install/update once; preserve theme, font and settings.
  configure --fraction 0.75       Resize using a fraction of each screen's usable width/height.
  configure --apps com.apple.finder,com.apple.Safari  Manage bundle identifiers, or none (default: none).
  status                         Read worker status; exit 0 ready/idle, 2 permission, 3 not ready.
  permissions                    Open Accessibility settings and reveal the installed app.
  reload                         Reload config and recheck permission without rebuilding.
  stop                           Unload helper for this login; install starts it again.
  uninstall                      Move exact installation paths into the user's Trash.
HELP
}

# Tests may source the functions against isolated fixtures without dispatching commands.
if [ "${BASH_SOURCE[0]}" != "$0" ]; then return 0; fi

command=${1:-help}
if [ "$#" -gt 0 ]; then shift; fi
case "$command" in
    help|--help|-h) usage; exit 0 ;;
    build|install|configure|status|permissions|reload|stop|uninstall) require_macos ;;
    *) usage >&2; die "Unknown command: $command" ;;
esac
case "$command" in
    build) [ "$#" -eq 0 ] || die 'build takes no arguments.'; build ;;
    install) install "$@" ;;
    configure) configure "$@" ;;
    status) [ "$#" -eq 0 ] || die 'status takes no arguments.'; status ;;
    permissions)
        [ "$#" -eq 0 ] || die 'permissions takes no arguments.'; check_owned
        /usr/bin/open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility'
        /usr/bin/open -R "$app"
        printf 'Allow Mac Window Snap in Accessibility; add the revealed app if missing. Complete authentication yourself. Then run reload and status.\n' ;;
    reload) [ "$#" -eq 0 ] || die 'reload takes no arguments.'; check_owned; launchctl_cmd kill SIGHUP "$service"; printf 'Reload requested. Run status to verify.\n' ;;
    stop) [ "$#" -eq 0 ] || die 'stop takes no arguments.'; check_owned; unload ;;
    uninstall) [ "$#" -eq 0 ] || die 'uninstall takes no arguments.'; uninstall ;;
esac
