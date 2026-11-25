#!/usr/bin/env bash
# Build and run the tvOS app in the simulator. macOS + Xcode only.
#
#   scripts/app.sh build            compile for the tvOS Simulator
#   scripts/app.sh run              build, boot the simulator, install, launch
#   scripts/app.sh run-dev [SCREEN] [LANG]
#                                   the same, signed in as the dev account
#                                   (~/.config/matine/dev-account) on SCREEN
#                                   (add|picker|pin|home|settings|manage|item:ID|library:ID|search|play:ID|resume:ID)
#                                   in LANG (es-ES|en-US). Further arguments go to the
#                                   app, e.g. -MatineDevStopAfter 15 closes the player.
#                                   Debug builds only; the hook is compiled out of Release.
#   scripts/app.sh uitest [TEST] [DIR]
#                                   the UI tests (MatineUITests), signed in as the dev
#                                   account: the accessibility audit and remote-driven
#                                   tours; TEST is e.g. testTour, DIR collects screenshots
#   scripts/app.sh shot FILE.png    screenshot the running simulator
#   scripts/app.sh stop             quit the app and shut the simulator down
#
# MATINE_SIM picks the simulator by name (default "Apple TV 4K (4th generation)").
# Build output goes to .build/app so it stays out of Xcode's DerivedData.
set -euo pipefail
cd "$(dirname "$0")/.."

SIM_NAME="${MATINE_SIM:-Apple TV 4K (4th generation)}"
BUNDLE_ID=io.github.anthonytw.matine
DERIVED=.build/app

sim_id() {
    # The newest tvOS runtime's simulator of that name (as mobile.sh does, and as
    # xcodebuild's own name lookup would): the first in JSON order may be an old runtime.
    xcrun simctl list devices available -j | python3 -I -c '
import json, sys
name = sys.argv[1]
found = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    if "tvOS" not in runtime:
        continue
    for d in devices:
        if d["name"] == name and d["isAvailable"]:
            found.append((runtime, d["udid"]))
if not found:
    sys.exit("no available tvOS simulator named " + name)
import re
def version(runtime):   # numeric: iOS-9-0 sorts before iOS-27-0
    return [int(n) for n in re.findall(r"\d+", runtime)]
print(sorted(found, key=lambda f: version(f[0]))[-1][1])' "$SIM_NAME"
}

build() {
    local id
    id=$(sim_id)
    xcodebuild -project Apps/Matine/Matine.xcodeproj -scheme Matine -configuration Debug \
        -destination "id=$id" -derivedDataPath "$DERIVED" \
        -quiet build
}

install_and_launch() {   # extra arguments go to the app
    id=$(sim_id)
    xcrun simctl boot "$id" 2>/dev/null || true
    xcrun simctl bootstatus "$id" -b >/dev/null
    xcrun simctl install "$id" "$DERIVED/Build/Products/Debug-appletvsimulator/Matine.app"
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
uitest)
    dev_account
    sim=$(sim_id)
    only=()
    [[ -n ${2:-} ]] && only=(-only-testing:"MatineUITests/MatineUITests/$2")
    shots=${3:-}
    [[ -n $shots ]] && mkdir -p "$shots"
    TEST_RUNNER_MATINE_DEV_SERVER=$(field server) \
    TEST_RUNNER_MATINE_DEV_USER=$(field user) \
    TEST_RUNNER_MATINE_DEV_PASSWORD=$(field password) \
    TEST_RUNNER_MATINE_SHOTS=$shots \
        xcodebuild -project Apps/Matine/Matine.xcodeproj -scheme Matine -configuration Debug \
            -destination "id=$sim" -derivedDataPath "$DERIVED" \
            -quiet ${MATINE_RESULT:+-resultBundlePath "$MATINE_RESULT"} test "${only[@]}"
    ;;
run-dev)
    build
    dev_account
    SIMCTL_CHILD_MATINE_DEV_SERVER=$(field server) \
    SIMCTL_CHILD_MATINE_DEV_USER=$(field user) \
    SIMCTL_CHILD_MATINE_DEV_PASSWORD=$(field password) \
        install_and_launch -MatineDevScreen "${2:-home}" -MatineDevLanguage "${3:-es-ES}" "${@:4}"
    ;;
shot)
    id=$(sim_id)
    xcrun simctl io "$id" screenshot "${2:?scripts/app.sh shot FILE.png}"
    ;;
stop)
    id=$(sim_id)
    xcrun simctl terminate "$id" "$BUNDLE_ID" 2>/dev/null || true
    xcrun simctl shutdown "$id" 2>/dev/null || true
    ;;
*)
    sed -n '2,19p' "$0"
    exit 2
    ;;
esac
