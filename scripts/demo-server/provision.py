#!/usr/bin/env python3
"""Provisions the demo Jellyfin through its API (stdlib only), idempotently: startup wizard, an admin, the two
libraries (NFO + local images only, every remote fetcher off, nothing saved into the media folder), the `demo`
user (empty password, downloads + remote control allowed) and its watch state. Writes build/ids.json.

  provision.py [--server https://localhost:8920] [--cacert build/caddy-root.crt]
"""
import argparse, json, secrets, ssl, sys, time, urllib.request, urllib.error, urllib.parse
from datetime import datetime, timedelta, timezone
from pathlib import Path

from catalog import MOVIES, SHOWS

HERE = Path(__file__).resolve().parent
BUILD = HERE / "build"
TICKS = 10_000_000

ap = argparse.ArgumentParser()
ap.add_argument("--server", default="https://localhost:8920")
ap.add_argument("--cacert", default=str(BUILD / "caddy-root.crt"))
args = ap.parse_args()
CTX = ssl.create_default_context(cafile=args.cacert)
token = ""


def call(method: str, path: str, body=None, query=None, ok=(200, 204)):
    url = args.server + path + ("?" + urllib.parse.urlencode(query) if query else "")
    data = None if body is None else json.dumps(body).encode()
    h = {"Content-Type": "application/json",
         "Authorization": 'MediaBrowser Client="matine-demo", Device="provision", DeviceId="matine-demo-provision", '
                          f'Version="1.0"{", Token=" + chr(34) + token + chr(34) if token else ""}'}
    req = urllib.request.Request(url, data=data, method=method, headers=h)
    try:
        with urllib.request.urlopen(req, context=CTX, timeout=60) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {path} -> {e.code}: {e.read().decode()[:400]}")


def wait_up():
    for _ in range(90):
        try:
            return call("GET", "/System/Info/Public")
        except SystemExit:
            raise
        except Exception:
            time.sleep(2)
    sys.exit("server did not come up")


info = wait_up()
admin_pw_file = BUILD / "admin-password"
if info.get("StartupWizardCompleted") and not admin_pw_file.exists():
    sys.exit("admin password lost; demo-server.sh destroy && all")
if not info.get("StartupWizardCompleted"):
    admin_pw_file.write_text(secrets.token_urlsafe(18))
    call("POST", "/Startup/Configuration", {"UICulture": "en-US", "MetadataCountryCode": "US", "PreferredMetadataLanguage": "en"})
    call("GET", "/Startup/User")
    call("POST", "/Startup/User", {"Name": "admin", "Password": admin_pw_file.read_text()})
    call("POST", "/Startup/RemoteAccess", {"EnableRemoteAccess": True, "EnableAutomaticPortMapping": False})
    call("POST", "/Startup/Complete")
    print("wizard done")
auth = call("POST", "/Users/AuthenticateByName", {"Username": "admin", "Pw": admin_pw_file.read_text()})
token, admin_id = auth["AccessToken"], auth["User"]["Id"]


def library_options(types: list[str]) -> dict:
    return {
        "Enabled": True, "EnableArchiveMediaFiles": False, "EnablePhotos": False, "EnableRealtimeMonitor": False,
        "EnableLUFSScan": False, "ExtractTrickplayImagesDuringLibraryScan": False, "EnableTrickplayImageExtraction": False,
        "ExtractChapterImagesDuringLibraryScan": False, "EnableChapterImageExtraction": False,
        "SaveLocalMetadata": False, "SaveSubtitlesWithMedia": False, "SaveLyricsWithMedia": False,
        "EnableInternetProviders": False, "ImportMissingEpisodes": False, "AutomaticRefreshIntervalDays": 0,
        "PreferredMetadataLanguage": "en", "MetadataCountryCode": "US", "SeasonZeroDisplayName": "Specials",
        "MetadataSavers": [], "DisabledLocalMetadataReaders": [], "LocalMetadataReaderOrder": ["Nfo"],
        "DisabledSubtitleFetchers": [], "SubtitleFetcherOrder": [], "SkipSubtitlesIfEmbeddedSubtitlesPresent": False,
        "SkipSubtitlesIfAudioTrackMatches": False, "RequirePerfectSubtitleMatch": False, "AllowEmbeddedSubtitles": "AllowAll",
        "TypeOptions": [{"Type": t, "MetadataFetchers": [], "MetadataFetcherOrder": [], "ImageFetchers": [],
                         "ImageFetcherOrder": [], "ImageOptions": []} for t in types],
    }


folders = {f["Name"]: f for f in call("GET", "/Library/VirtualFolders")}
for name, ctype, path, types in [("Movies", "movies", "/media/movies", ["Movie"]),
                                 ("Shows", "tvshows", "/media/shows", ["Series", "Season", "Episode"])]:
    opts = library_options(types)
    if name in folders:
        call("POST", "/Library/VirtualFolders/LibraryOptions", {"Id": folders[name]["ItemId"], "LibraryOptions": opts})
    else:
        opts["PathInfos"] = [{"Path": path}]
        call("POST", "/Library/VirtualFolders", {"LibraryOptions": opts},
             {"name": name, "collectionType": ctype, "refreshLibrary": "false"})
        print("library", name)
    if path not in next(f for f in call("GET", "/Library/VirtualFolders") if f["Name"] == name)["Locations"]:
        call("POST", "/Library/VirtualFolders/Paths", {"Name": name, "PathInfo": {"Path": path}}, {"refreshLibrary": "false"})

call("POST", "/Library/Refresh")
want = len(MOVIES) + sum(1 + len(s["episodes"]) for s in SHOWS)
items: list = []
for _ in range(120):
    items = call("GET", "/Items", query={"userId": admin_id, "Recursive": "true", "IncludeItemTypes": "Movie,Series,Episode",
                                         "Fields": "RunTimeTicks,Tags,Taglines"})["Items"]
    if len(items) >= want and all(i.get("RunTimeTicks") or i["Type"] == "Series" for i in items):
        break
    time.sleep(3)
else:
    sys.exit(f"library scan incomplete: {len(items)}/{want} items")
by_name = {(i["Type"], i["Name"]): i for i in items}

# The demo user: empty password, non-admin, downloads + remote control allowed.
users = {u["Name"]: u for u in call("GET", "/Users")}
demo = users.get("demo") or call("POST", "/Users/New", {"Name": "demo", "Password": ""})
policy = call("GET", f"/Users/{demo['Id']}")["Policy"]
policy.update({"IsAdministrator": False, "EnableContentDownloading": True, "EnableRemoteAccess": True,
               "EnableRemoteControlOfOtherUsers": True, "EnableSharedDeviceControl": True,
               "EnableMediaPlayback": True, "EnableAllFolders": True, "EnableContentDeletion": False,
               "EnableUserPreferenceAccess": True, "EnableLiveTvAccess": False,
               "EnableCollectionManagement": False, "EnableSubtitleManagement": False})
call("POST", f"/Users/{demo['Id']}/Policy", policy)
admin_policy = call("GET", f"/Users/{admin_id}")["Policy"]
admin_policy["IsHidden"] = True   # the login picker lists `demo` only
call("POST", f"/Users/{admin_id}/Policy", admin_policy)
call("POST", f"/Users/{demo['Id']}/Configuration",
     {"PlayDefaultAudioTrack": True, "DisplayMissingEpisodes": False, "SubtitleMode": "Default", "EnableNextEpisodeAutoPlay": True,
      "HidePlayedInLatest": False, "RememberAudioSelections": True, "RememberSubtitleSelections": True,
      "GroupedFolders": [], "LatestItemsExcludes": [], "MyMediaExcludes": [], "OrderedViews": [], "SubtitleLanguagePreference": ""})


def set_state(item: dict, *, position: float = 0, played: bool = False, favorite: bool = False, ago_days: int = 1):
    ticks = int(item.get("RunTimeTicks", 0) * position)
    when = (datetime.now(timezone.utc) - timedelta(days=ago_days)).strftime("%Y-%m-%dT%H:%M:%S.0000000Z")
    body = {"PlaybackPositionTicks": ticks, "PlayCount": 1 if played else 0, "IsFavorite": favorite, "Played": played}
    if played or position:
        body["LastPlayedDate"] = when
    call("POST", f"/UserItems/{item['Id']}/UserData", body, {"userId": demo["Id"]})


ids = {}
for m in MOVIES:
    item = by_name[("Movie", m["title"])]
    ids[m["slug"]] = item["Id"]
    if m.get("resume") or m.get("watched") or m.get("favorite"):
        set_state(item, position=m.get("resume", 0), played=bool(m.get("watched")), favorite=bool(m.get("favorite")),
                  ago_days=2 if m.get("resume") else 4)
for s in SHOWS:
    series = by_name[("Series", s["title"])]
    ids[s["slug"]] = series["Id"]
    if s.get("favorite"):
        set_state(series, favorite=True, played=False)
    for e in s["episodes"]:
        item = by_name[("Episode", e["title"])]
        ids[e["slug"]] = item["Id"]
        if e.get("resume") or e.get("watched"):
            set_state(item, position=e.get("resume", 0), played=bool(e.get("watched")), ago_days=1 if e.get("resume") else 2)

# Re-read every NFO and image in place (the item ids do not change): used after a catalog or NFO edit.
for item in by_name.values():
    full = call("GET", f"/Items/{item['Id']}", query={"userId": admin_id})
    if full.get("LockData") or full.get("LockedFields"):   # earlier NFOs said lockdata: unlock so the refresh may overwrite
        full["LockData"], full["LockedFields"] = False, []
        call("POST", f"/Items/{item['Id']}", full)
    call("POST", f"/Items/{item['Id']}/Refresh", query={"metadataRefreshMode": "FullRefresh", "imageRefreshMode": "FullRefresh",
                                                          "replaceAllMetadata": "true", "replaceAllImages": "true"})
time.sleep(20)

ids_file = BUILD / "ids.json"
old_ids = json.loads(ids_file.read_text()) if ids_file.exists() else {}
for k, v in old_ids.items():   # the ids of earlier runs must not change: a mismatch means the library was rebuilt
    if k in ids and ids[k] != v:
        print(f"warning: id of {k} changed ({v} -> {ids[k]})", file=sys.stderr)
ids_file.write_text(json.dumps(ids, indent=2) + "\n")   # only what the catalog holds: dropped slugs leave ONLY_ITEMS
print(json.dumps(ids, indent=2))
