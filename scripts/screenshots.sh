#!/usr/bin/env bash
# App Store + website screenshots from the local demo server, scripts/demo-server/ (docs/appstore/screenshots.md).
# Never the owner's library, household or accounts. Needs Xcode on a Mac. Nothing is uploaded.
#
#   scripts/screenshots.sh tv       # Apple TV 4K simulator, 3840x2160 (or 1920x1080)
#   scripts/screenshots.sh iphone   # newest iPhone Pro Max simulator (6.9"), 1320x2868
#   scripts/screenshots.sh ipad     # iPad Pro 13-inch simulator, 2064x2752 portrait + 2752x2064 landscape Home
#   scripts/screenshots.sh all      # all three (the default), then the website set
#   MATINE_SHOTS_LANG=es-ES|en-US   # one language (default: both)
#
# Output: build/screenshots/<lang>/<set>/NN-name.png and build/screenshots/web/<name>.webp (en-US).
set -euo pipefail
cd "$(dirname "$0")/.."

# The local, copyright-safe demo server (scripts/demo-server/: CC BY and US public-domain titles, art made
# from the films' own frames). Its Caddy CA is trusted in each simulator before the app runs.
SERVER=${MATINE_SHOTS_SERVER:-https://localhost:8920}
CA=scripts/demo-server/build/caddy-root.crt
IDS=scripts/demo-server/build/ids.json
[[ -f $CA && -f $IDS ]] || { echo "error: no demo server build (run scripts/demo-server/demo-server.sh all)" >&2; exit 1; }
curl -sf --max-time 10 --cacert "$CA" "$SERVER/System/Info/Public" >/dev/null || { echo "error: the demo server at $SERVER does not answer" >&2; exit 1; }
id_of() {   # SLUG: its item id on the demo server
    python3 -I -c 'import json,sys
ids = json.load(open(sys.argv[1]))
if sys.argv[2] not in ids: sys.exit(f"error: {sys.argv[1]} has no {sys.argv[2]}; rerun scripts/demo-server/demo-server.sh provision")
print(ids[sys.argv[2]])' "$IDS" "$1"
}
SEARCH=${MATINE_SHOTS_SEARCH:-animation}
BUNDLE_ID=io.github.anthonytw.matine
out=build/screenshots
mkdir -p "$out"
out=$(cd "$out" && pwd)
langs=${MATINE_SHOTS_LANG:-"en-US es-ES"}
target=${1:-all}

# Film ids on the demo server: freely licensed titles.
# A different title in each shot, so a set shows the range of the library.
DETAIL=$(id_of sintel)             # Apple TV film page: Sintel (CC BY 3.0), part watched
SERIES=$(id_of caminandes)         # Apple TV series page: Caminandes (CC BY)
PHONE_DETAIL=$(id_of spring)       # iPhone film page: Spring (CC BY 4.0)
PHONE_SERIES=$(id_of apollo)       # iPhone series page: Apollo: The NASA Films (public domain)
PAD_DETAIL=$(id_of trip)           # iPad film page: A Trip to the Moon (1902, public domain)
PHONE_SEARCH=${MATINE_SHOTS_PHONE_SEARCH:-moon}

# Every title on the demo server is CC BY or US public domain (scripts/demo-server/CREDITS.md); the allowlist
# (-MatineDevOnlyItems, debug builds only) is all of them, so nothing else can ever appear.
ONLY_ITEMS=$(python3 -I -c 'import json,sys; print(",".join(json.load(open(sys.argv[1])).values()))' "$IDS")

pixels() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ {w=$2} /pixelHeight/ {h=$2} END {print w "x" h}'; }

check_sizes() {   # DIR "WxH WxH"
    local f size s ok bad=0
    for f in "$1"/*.png; do
        [[ $f == *-landscape.png ]] && continue   # checked on its own, before and after turning
        size=$(pixels "$f"); ok=0
        for s in $2; do [[ $size == "$s" ]] && ok=1; done
        if [[ $ok == 0 ]]; then echo "error: $f is $size, want one of: $2" >&2; bad=1; fi
    done
    [[ $bad == 0 ]] || exit 1
}

sim_by_name() {   # NAME PLATFORM: newest runtime's available simulator of that exact name
    xcrun simctl list devices available -j | python3 -I -c '
import json, re, sys
name, platform = sys.argv[1:3]
found = [(runtime, d["udid"]) for runtime, ds in json.load(sys.stdin)["devices"].items() if platform in runtime
         for d in ds if d["name"] == name and d["isAvailable"]]
if not found: sys.exit("no available simulator named " + name)
print(sorted(found, key=lambda f: [int(n) for n in re.findall(r"\d+", f[0])])[-1][1])' "$1" "$2"
}

newest_pro_max() {   # the newest "iPhone NN Pro Max"
    xcrun simctl list devices available -j | python3 -I -c '
import json, re, sys
found = []
for runtime, ds in json.load(sys.stdin)["devices"].items():
    if "iOS" not in runtime: continue
    for d in ds:
        m = re.fullmatch(r"iPhone (\d+) Pro Max", d["name"])
        if m and d["isAvailable"]:
            found.append((int(m.group(1)), [int(n) for n in re.findall(r"\d+", runtime)], d["name"]))
print(sorted(found)[-1][2])'
}

booted_by_us=()
boot() {   # UDID
    if [[ $(xcrun simctl list devices -j | python3 -I -c 'import json,sys
for ds in json.load(sys.stdin)["devices"].values():
    for d in ds:
        if d["udid"] == sys.argv[1]: print(d["state"])' "$1") != Booted ]]; then
        xcrun simctl boot "$1"; booted_by_us+=("$1")
    fi
    xcrun simctl bootstatus "$1" -b >/dev/null
    xcrun simctl keychain "$1" add-root-cert "$CA"   # the demo server's local CA
}
cleanup() {
    local id
    for id in ${booted_by_us[@]+"${booted_by_us[@]}"}; do
        xcrun simctl status_bar "$id" clear 2>/dev/null || true
        xcrun simctl shutdown "$id" 2>/dev/null || true
    done
}
trap cleanup EXIT

# The status bar's date follows the simulator's language: write it, and reboot once if it changed.
set_sim_language() {   # UDID LANG
    local sim=$1 lang=${2%%-*} locale=${2//-/_}
    if [[ $(xcrun simctl spawn "$sim" defaults read -g AppleLanguages 2>/dev/null | tr -d ' \n()"') != "$lang"* ]]; then
        xcrun simctl spawn "$sim" defaults write -g AppleLanguages -array "$lang"
        xcrun simctl spawn "$sim" defaults write -g AppleLocale "$locale"
        xcrun simctl shutdown "$sim"; xcrun simctl boot "$sim"; xcrun simctl bootstatus "$sim" -b >/dev/null
    fi
}

mobile() {   # SET(iphone|ipad) SIMNAME SIZES
    local set=$1 name=$2 sizes=$3 sim lang dir
    sim=$(sim_by_name "$name" iOS)
    echo "== $set: $name ($sim)"
    xcodebuild -project Apps/MatineMobile/MatineMobile.xcodeproj -scheme MatineMobile -configuration Debug \
        -destination "id=$sim" -derivedDataPath .build/mobile -quiet build
    boot "$sim"
    xcrun simctl ui "$sim" appearance light
    xcrun simctl uninstall "$sim" "$BUNDLE_ID" 2>/dev/null || true   # no profile from an earlier run
    xcrun simctl install "$sim" .build/mobile/Build/Products/Debug-iphonesimulator/MatineMobile.app
    for lang in $langs; do
        set_sim_language "$sim" "$lang"
        if [[ $set == iphone ]]; then
            xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
                --cellularMode active --cellularBars 4 --operatorName "" --batteryState charged --batteryLevel 100
        else
            xcrun simctl status_bar "$sim" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
                --cellularMode notSupported --batteryState charged --batteryLevel 100
        fi
        dir="$out/$lang/$set"; rm -rf "$dir"; mkdir -p "$dir"
        shoot() {   # FILE SCREEN [extra launch arguments]
            local file=$1 screen=$2; shift 2
            xcrun simctl terminate "$sim" "$BUNDLE_ID" 2>/dev/null || true
            SIMCTL_CHILD_MATINE_DEV_SERVER=$SERVER SIMCTL_CHILD_MATINE_DEV_USER=demo SIMCTL_CHILD_MATINE_DEV_PASSWORD= \
                xcrun simctl launch "$sim" "$BUNDLE_ID" -MatineDevScreen "$screen" -MatineDevLanguage "$lang" \
                -MatineDevName Ana -MatineDevOnlyItems "$ONLY_ITEMS" ${@+"$@"} >/dev/null
            sleep "${MATINE_SHOTS_WAIT:-14}"   # sign-in, the rows, and every poster
            xcrun simctl io "$sim" screenshot --type=png "$dir/$file.png" 2>/dev/null
        }
        shoot 01-home home
        if [[ $set == iphone ]]; then shoot 02-detail "item:$PHONE_DETAIL"; else shoot 02-detail "item:$PAD_DETAIL"; fi
        if [[ $set == iphone ]]; then
            shoot 03-search search -MatineDevSearch "$PHONE_SEARCH"
            shoot 04-series "item:$PHONE_SERIES"
        fi
        if [[ $set == ipad ]]; then
            # 03-home-landscape: the same Home, wide (a UI test rotates the simulator; simctl cannot).
            local status=0
            xcrun simctl terminate "$sim" "$BUNDLE_ID" 2>/dev/null || true
            TEST_RUNNER_MATINE_DEV_SERVER=$SERVER TEST_RUNNER_MATINE_DEV_USER=demo TEST_RUNNER_MATINE_DEV_PASSWORD= \
            TEST_RUNNER_MATINE_SHOTS="$dir" TEST_RUNNER_MATINE_SHOTS_FILE=03-home-landscape TEST_RUNNER_MATINE_SHOTS_SCREEN=home \
            TEST_RUNNER_MATINE_SHOTS_LANG=$lang TEST_RUNNER_MATINE_SHOTS_ITEMS="$ONLY_ITEMS" \
                xcodebuild -project Apps/MatineMobile/MatineMobile.xcodeproj -scheme MatineMobile -configuration Debug \
                    -destination "id=$sim" -derivedDataPath .build/mobile -quiet \
                    test -only-testing:MatineMobileUITests/MatineMobileUITests/testLandscapeShot || status=$?
            local land="$dir/03-home-landscape.png"
            [[ -f $land ]] || { echo "error: ipad $lang: no landscape shot (xcodebuild ${status:-0})" >&2; exit 1; }
            [[ ${status:-0} == 0 ]] || echo "warning: ipad $lang: xcodebuild exited $status after the landscape shot was written" >&2
            # XCUIScreen captures in the device's portrait frame: turn it upright (landscapeLeft puts the top at the right).
            [[ $(pixels "$land") == 2064x2752 ]] || { echo "error: $land is $(pixels "$land") before turning, want 2064x2752" >&2; exit 1; }
            sips -r 270 "$land" >/dev/null
            [[ $(pixels "$land") == 2752x2064 ]] || { echo "error: $land is $(pixels "$land"), want 2752x2064" >&2; exit 1; }
        fi
        xcrun simctl terminate "$sim" "$BUNDLE_ID" 2>/dev/null || true
        check_sizes "$dir" "$sizes"
        echo "$set $lang: $dir"
    done
}

tv() {
    local sim lang dir
    sim=$(sim_by_name "Apple TV 4K (4th generation)" tvOS)
    echo "== tv: $sim"
    boot "$sim"
    for lang in $langs; do
        # No profile from an earlier run or language (the picker shot adds made-up ones, which also
        # make Home show the "kid profiles without a PIN" notice).
        xcrun simctl uninstall "$sim" "$BUNDLE_ID" 2>/dev/null || true
        set_sim_language "$sim" "$lang"   # the picker and the keyboard follow the system language
        dir="$out/$lang/tv"; rm -rf "$dir" "$out/tv-$lang.xcresult"; mkdir -p "$dir"
        # testStoreShots (MatineUITests) drives the Siri Remote and writes MATINE_SHOTS/NN-name.png.
        local status=0
        TEST_RUNNER_MATINE_DEV_SERVER=$SERVER TEST_RUNNER_MATINE_DEV_USER=demo TEST_RUNNER_MATINE_DEV_PASSWORD= \
        TEST_RUNNER_MATINE_SHOTS="$dir" TEST_RUNNER_MATINE_SHOTS_LANG=$lang TEST_RUNNER_MATINE_SHOTS_ITEMS="$ONLY_ITEMS" \
        TEST_RUNNER_MATINE_SHOTS_DETAIL=$DETAIL TEST_RUNNER_MATINE_SHOTS_SERIES=$SERIES TEST_RUNNER_MATINE_SHOTS_SEARCH=$SEARCH \
            xcodebuild -project Apps/Matine/Matine.xcodeproj -scheme Matine -configuration Debug \
                -destination "id=$sim" -derivedDataPath .build/app -quiet -resultBundlePath "$out/tv-$lang.xcresult" \
                test -only-testing:MatineUITests/MatineUITests/testStoreShots || status=$?
        # testmanagerd crashed once after the last shot was saved: the shots count, the exit status does not.
        if [[ $status != 0 ]]; then
            [[ $(ls "$dir"/*.png 2>/dev/null | wc -l) -ge 5 ]] || { echo "error: tv $lang: tests failed ($status) and shots are missing" >&2; exit 1; }
            echo "warning: tv $lang: xcodebuild exited $status after all five shots were written" >&2
        fi
        check_sizes "$dir" "3840x2160 1920x1080"
        echo "tv $lang: $dir"
    done
}

web() {   # en-US shots for the website, 1600 px at most on the long side, WebP when cwebp exists
    local dir="$out/web" ext=png
    command -v cwebp >/dev/null && ext=webp
    rm -rf "$dir"; mkdir -p "$dir"
    local pair set shot name tmp
    for pair in tv:01-home:tv-home tv:02-detail:tv-detail tv:04-profiles:tv-profiles tv:05-search:tv-search \
                iphone:01-home:iphone-home iphone:02-detail:iphone-detail iphone:04-downloads:iphone-downloads ipad:01-home:ipad-home ipad:03-home-landscape:ipad-home-wide; do
        IFS=: read -r set shot name <<<"$pair"
        [[ -r $out/en-US/$set/$shot.png ]] || { echo "web: no $set/$shot (skipped)"; continue; }
        tmp="$dir/$name.png"
        cp "$out/en-US/$set/$shot.png" "$tmp"
        sips -Z 1600 "$tmp" >/dev/null
        if [[ $ext == webp ]]; then cwebp -quiet -q 85 "$tmp" -o "$dir/$name.webp"; rm "$tmp"; fi
    done
    echo "web: $dir"
}

case "$target" in
    tv) tv ;;
    iphone) mobile iphone "$(newest_pro_max)" "1320x2868" ;;
    ipad) mobile ipad "iPad Pro 13-inch (M5)" "2064x2752" ;;
    web) ;;
    all) tv; mobile iphone "$(newest_pro_max)" "1320x2868"; mobile ipad "iPad Pro 13-inch (M5)" "2064x2752" ;;
    *) echo "usage: $0 [tv|iphone|ipad|all|web]" >&2; exit 2 ;;
esac
case " $langs " in *" en-US "*) web ;; esac
