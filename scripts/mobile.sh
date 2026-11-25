#!/usr/bin/env bash
# Build and run the iPhone + iPad app in the simulator. macOS + Xcode only.
#
#   scripts/mobile.sh build              compile for the iOS Simulator
#   scripts/mobile.sh run                build, boot the simulator, install, launch
#   scripts/mobile.sh run-dev [SCREEN] [LANG]
#                                        the same, signed in as the dev account
#                                        (~/.config/matine/dev-account) on SCREEN
#                                        (add|picker|pin|home|profile|libraries|item:ID|library:ID|search|play:ID|resume:ID)
#                                        in LANG (es-ES|en-US). Further arguments go to the
#                                        app, e.g. -MatineDevStopAfter 15 closes the player,
#                                        -MatineDevSearch TEXT types a search.
#                                        Debug builds only; the hook is compiled out of Release.
#   scripts/mobile.sh uitest [TEST] [ITEM_ID]
#                                        the UI tests (MatineMobileUITests), signed in as the dev account:
#                                        TEST e.g. testPlayThenClose; ITEM_ID is an item the account can play
#   scripts/mobile.sh shot FILE.png      screenshot the running simulator
#   scripts/mobile.sh stop               quit the app and shut down the simulator this script booted
#
# MATINE_SIM picks the simulator by name (default "iPhone 17"; try "iPad Pro 11-inch (M5)").
# Simulators of the same name exist per runtime: the newest runtime wins.
# Build output goes to .build/mobile so it stays out of Xcode's DerivedData.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${MATINE_SIM:-iPhone 17}"
BUNDLE_ID=io.github.anthonytw.matine
DERIVED=.build/mobile
BOOTED_MARK=".build/mobile-booted"   # UDIDs this script booted, so `stop` leaves other simulators alone

sim_id() {
    xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime:
        continue
    for d in devices:
        if d["name"] == name and d["isAvailable"]:
            found.append((runtime, d["udid"]))
if not found:
    sys.exit("no available simulator named " + name)
import re
def version(runtime):   # numeric: iOS-9-0 sorts before iOS-27-0
    return [int(n) for n in re.findall(r"\d+", runtime)]
print(sorted(found, key=lambda f: version(f[0]))[-1][1])' "$SIM_NAME"
}

build() {
    local id
    id=$(sim_id)
    xcodebuild -project Apps/MatineMobile/MatineMobile.xcodeproj -scheme MatineMobile -configuration Debug \
        -destination "id=$id" -derivedDataPath "$DERIVED" \
        -quiet build
}

install_and_launch() {   # extra arguments go to the app
    id=$(sim_id)
    if [[ $(xcrun simctl list devices -j | python3 -I -c 'import json,sys
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if d["udid"] == sys.argv[1]: print(d["state"])' "$id") != Booted ]]; then
        xcrun simctl boot "$id"
        mkdir -p .build && echo "$id" >> "$BOOTED_MARK"
    fi
    xcrun simctl bootstatus "$id" -b >/dev/null
    xcrun simctl install "$id" "$DERIVED/Build/Products/Debug-iphonesimulator/MatineMobile.app"
    xcrun simctl terminate "$id" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl launch "$id" "$BUNDLE_ID" "$@"
}

dev_account() {   # defines field NAME for ~/.config/matine/dev-account
    account="$HOME/.config/matine/dev-account"
    [[ -r $account ]] || { echo "no $account (see README)" >&2; exit 1; }
    field() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$account" | tr -d '\r' | sed 's/[[:space:]]*$//'; }
}

case "${1:-}" in
build)
    build
    ;;
run)
    build
    install_and_launch
    ;;
run-dev)
    build
    dev_account
    SIMCTL_CHILD_MATINE_DEV_SERVER=$(field server) \
    SIMCTL_CHILD_MATINE_DEV_USER=$(field user) \
    SIMCTL_CHILD_MATINE_DEV_PASSWORD=$(field password) \
        install_and_launch -MatineDevScreen "${2:-home}" -MatineDevLanguage "${3:-es-ES}" "${@:4}"
    ;;
uitest)
    dev_account
    sim=$(sim_id)
    only=()
    [[ -n ${2:-} ]] && only=(-only-testing:"MatineMobileUITests/MatineMobileUITests/$2")
    TEST_RUNNER_MATINE_DEV_SERVER=$(field server) \
    TEST_RUNNER_MATINE_DEV_USER=$(field user) \
    TEST_RUNNER_MATINE_DEV_PASSWORD=$(field password) \
    TEST_RUNNER_MATINE_UITEST_ITEM=${3:-} \
        xcodebuild -project Apps/MatineMobile/MatineMobile.xcodeproj -scheme MatineMobile -configuration Debug \
            -destination "id=$sim" -derivedDataPath "$DERIVED" \
            -quiet ${MATINE_RESULT:+-resultBundlePath "$MATINE_RESULT"} test "${only[@]}"
    ;;
shot)
    id=$(sim_id)
    xcrun simctl io "$id" screenshot "${2:?scripts/mobile.sh shot FILE.png}"
    ;;
stop)
    id=$(sim_id)
    xcrun simctl terminate "$id" "$BUNDLE_ID" 2>/dev/null || true
    # Only a simulator this script booted is shut down.
    if [[ -r $BOOTED_MARK ]] && grep -qx "$id" "$BOOTED_MARK"; then
        xcrun simctl shutdown "$id" 2>/dev/null || true
        grep -vx "$id" "$BOOTED_MARK" > "$BOOTED_MARK.tmp" || true
        mv "$BOOTED_MARK.tmp" "$BOOTED_MARK"
    fi
    ;;
*)
    sed -n '2,19p' "$0"
    exit 2
    ;;
esac
