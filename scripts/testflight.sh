#!/usr/bin/env bash
# Archive Matiné from a clean checkout of REF (default: origin/main) and upload it to TestFlight.
#
#   scripts/testflight.sh [--export-only] [--yes] [--platform tvos|ios|all] [REF]
#
#   --export-only   archive and export a signed package into the output folder; upload nothing
#   --yes           upload without asking
#   --platform P    tvos, ios or all (default all): each archived from the same checkout, same build number
#
# The build number is MATINE_BUILD_BASE (default 100) plus the commit count of REF, so every new
# commit on main uploads higher. The public history starts from one commit, and builds up to 43 were
# uploaded before that, so the base keeps new numbers above them.
# The marketing version is MARKETING_VERSION in the project.
#
# Signing: the Release configuration signs manually with the App Store profile "Matine tvOS App
# Store" (`uv run scripts/asc.py profile` makes it) and the team's Apple Distribution certificate in
# the keychain, from the archive on. (Automatic signing would need a tvOS development profile, which
# Apple only issues once an Apple TV is registered to the team.) The team id comes in on the command
# line, never in the project. Configuration comes from
# ${MATINE_ASC_ENV:-~/.config/matine/release.env}: ASC_TEAM_ID, ASC_KEY_PATH, ASC_KEY_ID,
# ASC_ISSUER_ID, optional ASC_KEYCHAIN (+ ASC_KEYCHAIN_PASSWORD_FILE) and ASC_BETA_GROUP (asc.py).
# Nothing of it lives in this repository.
set -euo pipefail
repo=$(cd "$(dirname "$0")/.." && pwd)
die() { echo "testflight: $*" >&2; exit 1; }

export_only=false yes=false platform=all ref=origin/main
while [[ $# -gt 0 ]]; do
  case "$1" in
    --export-only) export_only=true ;;
    --yes) yes=true ;;
    --platform) platform=${2:?--platform needs a value}; shift ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) ref=$1 ;;
  esac
  shift
done

env_file=${MATINE_ASC_ENV:-$HOME/.config/matine/release.env}
[[ -r $env_file ]] || die "no $env_file"
# shellcheck disable=SC1090
set -a; source "$env_file"; set +a
team=${ASC_TEAM_ID:?ASC_TEAM_ID missing}
key_path=${ASC_KEY_PATH/#\~/$HOME}
[[ -r $key_path ]] || die "the API key file is missing"
case "$key_path" in "$repo"/*) die "the API key must not live inside the repository" ;; esac
auth=(-authenticationKeyPath "$key_path" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
cert="Apple Distribution"

case "$platform" in tvos|ios|all) ;; *) die "--platform must be tvos, ios or all" ;; esac
git -C "$repo" fetch -q origin
sha=$(git -C "$repo" rev-parse --verify "$ref^{commit}") || die "no commit $ref"
build=$(( ${MATINE_BUILD_BASE:-100} + $(git -C "$repo" rev-list --count "$sha") ))
out=${MATINE_TF_OUT:-${TMPDIR:-/tmp}/matine-testflight}
case "$out" in ""|/|"$HOME"|"$HOME"/) die "refusing to clear $out" ;; esac
rm -rf "$out"; mkdir -p "$out"
work="$out/src"
git -C "$repo" worktree prune
git -C "$repo" worktree add -q --detach "$work" "$sha"
trap 'git -C "$repo" worktree remove --force "$work" >/dev/null 2>&1 || true' EXIT
version=$(sed -n 's/.*MARKETING_VERSION = \(.*\);/\1/p' "$work/Apps/Matine/Matine.xcodeproj/project.pbxproj" | head -1)
echo "Matiné $version ($build) from ${sha:0:7}; output $out"

if [[ $export_only == false && $yes == false ]]; then
  [[ -t 0 ]] || die "not a terminal: pass --yes to upload without asking"
  read -r -p "Upload build $build to TestFlight? [y/N] " answer
  [[ $answer == [yY]* ]] || { echo "Stopped; nothing built or uploaded."; exit 1; }
fi

if [[ -n ${ASC_KEYCHAIN:-} ]]; then
  kc=${ASC_KEYCHAIN/#\~/$HOME}
  if [[ -n ${ASC_KEYCHAIN_PASSWORD_FILE:-} ]]; then
    # the password goes in on stdin, never in argv (where `ps` would show it)
    security unlock-keychain "$kc" < "${ASC_KEYCHAIN_PASSWORD_FILE/#\~/$HOME}" || die "could not unlock the keychain"
  else
    security unlock-keychain "$kc" || die "could not unlock the keychain"
  fi
fi
# Homebrew's rsync breaks Xcode's packaging: the system tools first.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

destination=upload
[[ $export_only == true ]] && destination=export

# build_one NAME PROJECT SCHEME DESTINATION PROFILES-XML
build_one() {
  local name=$1 project=$2 scheme=$3 dest=$4 profiles=$5 o="$out/$1"
  mkdir -p "$o"
  cat > "$o/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string>
<key>destination</key><string>$destination</string>
<key>teamID</key><string>$team</string>
<key>signingStyle</key><string>manual</string>
<key>signingCertificate</key><string>$cert</string>
<key>provisioningProfiles</key><dict>$profiles</dict>
<key>manageAppVersionAndBuildNumber</key><false/>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
  chmod 600 "$o/ExportOptions.plist"
  echo "[$name] archiving (log: $o/archive.log)"
  xcodebuild archive -project "$work/$project" -scheme "$scheme" -configuration Release \
    -destination "$dest" -archivePath "$o/$scheme.xcarchive" -derivedDataPath "$o/dd.noindex" \
    "DEVELOPMENT_TEAM=$team" "CURRENT_PROJECT_VERSION=$build" \
    >"$o/archive.log" 2>&1 || { tail -30 "$o/archive.log"; die "$name archive failed"; }
  echo "[$name] exporting$([[ $export_only == true ]] || echo " and uploading") (log: $o/export.log)"
  xcodebuild -exportArchive -archivePath "$o/$scheme.xcarchive" -exportOptionsPlist "$o/ExportOptions.plist" \
    -exportPath "$o/export" -allowProvisioningUpdates "${auth[@]}" \
    >"$o/export.log" 2>&1 || { tail -30 "$o/export.log"; die "$name export failed"; }
  if [[ $export_only == true ]]; then
    echo "[$name] exported: $(ls "$o/export"/*.ipa)"
  else
    echo "[$name] uploaded build $build; it shows in App Store Connect after processing (uv run scripts/asc.py builds)"
  fi
}

if [[ $platform == tvos || $platform == all ]]; then
  build_one tvos Apps/Matine/Matine.xcodeproj Matine 'generic/platform=tvOS' \
    "<key>io.github.anthonytw.matine</key><string>Matine tvOS App Store</string><key>io.github.anthonytw.matine.topshelf</key><string>Matine TopShelf tvOS App Store</string>"
fi
if [[ $platform == ios || $platform == all ]]; then
  build_one ios Apps/MatineMobile/MatineMobile.xcodeproj MatineMobile 'generic/platform=iOS' \
    "<key>io.github.anthonytw.matine</key><string>Matine iOS App Store</string>"
fi
