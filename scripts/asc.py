# /// script
# dependencies = ["pyjwt[crypto]==2.10.1", "requests==2.32.3"]
# ///
"""App Store Connect chores for Matiné, with the team's API key.

    uv run scripts/asc.py status          bundle id, app record, groups, latest builds
    uv run scripts/asc.py bundle-id       register io.github.anthonytw.matine (once)
    uv run scripts/asc.py group           create the internal TestFlight group and add every team member
    uv run scripts/asc.py builds          recent builds and their processing state
    uv run scripts/asc.py profile         make/refresh the tvOS and iOS App Store provisioning profiles and install them
    uv run scripts/asc.py add-ios         add the iOS platform (an iOS appStoreVersion) to the app record
    uv run scripts/asc.py listing [--apply]   compare (or write) the store listing with docs/appstore/listing.json:
                                          name, subtitle, description, keywords, URLs, categories, version, copyright, review notes
    uv run scripts/asc.py screenshots [DIR] [--apply]   list (or replace) the store screenshots from DIR
                                          (default build/screenshots: <lang>/{tv,iphone,ipad}/NN-name.png, from
                                          scripts/screenshots.sh), per platform, language and display size

Reads the key from MATINE_ASC_ENV (default ~/.config/matine/release.env:
ASC_KEY_PATH, ASC_KEY_ID, ASC_ISSUER_ID; ASC_BETA_GROUP names the internal
TestFlight group, default "Internal").
Never prints key material. The app record itself can't be created through the
API: that one step is the web UI (README "TestFlight").
"""
import hashlib, json, os, re, sys, time
from pathlib import Path
import jwt, requests

BUNDLE_ID = "io.github.anthonytw.matine"
# Each bundle id and the App Store profile Release signs it with.
TARGETS = {
    BUNDLE_ID: "Matine tvOS App Store",
    BUNDLE_ID + ".topshelf": "Matine TopShelf tvOS App Store",
}
IOS_PROFILE = "Matine iOS App Store"
API = "https://api.appstoreconnect.apple.com"

def env():
    path = Path(os.environ.get("MATINE_ASC_ENV", "~/.config/matine/release.env")).expanduser()
    values = {}
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            k, v = line.split("=", 1)
            values[k.removeprefix("export ").strip()] = v.strip().strip('"').strip("'")
    return values

def token(e):
    key = Path(os.path.expanduser(e["ASC_KEY_PATH"])).read_text()
    now = int(time.time())
    return jwt.encode({"iss": e["ASC_ISSUER_ID"], "iat": now, "exp": now + 900, "aud": "appstoreconnect-v1"},
                      key, algorithm="ES256", headers={"kid": e["ASC_KEY_ID"], "typ": "JWT"})

class ASC:
    def __init__(self):
        self.s = requests.Session()
        self.s.headers["Authorization"] = "Bearer " + token(env())

    def get(self, path, **params):
        r = self.s.get(API + path, params=params, timeout=30)
        r.raise_for_status()
        return r.json()

    def post(self, path, body):
        r = self.s.post(API + path, json=body, timeout=30)
        if r.status_code >= 400:
            sys.exit(f"{path}: HTTP {r.status_code}: {r.json().get('errors', [{}])[0].get('detail', r.text)[:300]}")
        return r.json() if r.content else {}

    def patch(self, path, body):
        r = self.s.patch(API + path, json=body, timeout=30)
        if r.status_code >= 400:
            errs = r.json().get("errors", [{}]) if r.content else [{}]
            sys.exit(f"{path}: HTTP {r.status_code}: " + "; ".join(e.get("detail", e.get("title", "")) for e in errs)[:500])
        return r.json() if r.content else {}

    def bundle(self, identifier=BUNDLE_ID):
        data = self.get("/v1/bundleIds", **{"filter[identifier]": identifier})["data"]
        return next((b for b in data if b["attributes"]["identifier"] == identifier), None)

    def app(self):
        data = self.get("/v1/apps", **{"filter[bundleId]": BUNDLE_ID})["data"]
        return data[0] if data else None

    def versions(self, app_id):
        return self.get(f"/v1/apps/{app_id}/appStoreVersions", limit=50)["data"]

    def groups(self, app_id):
        return self.get(f"/v1/apps/{app_id}/betaGroups")["data"]

def status(asc):
    for identifier in TARGETS:
        b = asc.bundle(identifier)
        print(f"bundle id {identifier}: {'registered (' + b['attributes']['platform'] + ')' if b else 'not registered'}")
    a = asc.app()
    if not a:
        print("app record: not created yet (web UI step)")
        return
    print(f"app record: {a['attributes']['name']} (id {a['id']})")
    for v in asc.versions(a["id"]):
        at = v["attributes"]
        print(f"platform {at['platform']}: version {at['versionString']} · {at['appStoreState']}")
    for g in asc.groups(a["id"]):
        print(f"group: {g['attributes']['name']} · internal={g['attributes']['isInternalGroup']}")
    builds(asc, a)

def builds(asc, a=None):
    a = a or asc.app()
    if not a: sys.exit("no app record yet")
    for b in asc.get("/v1/builds", **{"filter[app]": a["id"], "sort": "-uploadedDate", "limit": 5})["data"]:
        at = b["attributes"]
        print(f"build {at['version']} · {at['processingState']} · uploaded {at['uploadedDate'][:16]} · expires {at.get('expirationDate', '')[:10]}")

def bundle_id(asc):
    for identifier in TARGETS:
        if asc.bundle(identifier):
            print(identifier, "already registered"); continue
        name = "Matine" if identifier == BUNDLE_ID else "Matine " + identifier.rsplit(".", 1)[1]
        asc.post("/v1/bundleIds", {"data": {"type": "bundleIds", "attributes": {
            "identifier": identifier, "name": name, "platform": "UNIVERSAL"}}})
        print("registered", identifier)

def profile(asc):
    """A TVOS_APP_STORE profile per bundle id (app and Top Shelf extension), on
    the team's distribution certificate(s), installed where Xcode looks. An
    existing one is replaced: profiles can't be edited, only recreated."""
    for identifier, name in TARGETS.items():
        make_profile(asc, identifier, name)
    make_profile(asc, BUNDLE_ID, IOS_PROFILE, "IOS_APP_STORE")

def project_version():
    text = (Path(__file__).resolve().parent.parent / "Apps/MatineMobile/MatineMobile.xcodeproj/project.pbxproj").read_text()
    m = re.search(r"MARKETING_VERSION = ([0-9.]+);", text)
    if not m: sys.exit("no MARKETING_VERSION in the iOS project")
    return m.group(1)

def add_ios(asc):
    """Add the iOS platform: an unsubmitted iOS appStoreVersion matching MARKETING_VERSION.
    Idempotent. If Apple refuses, the web UI's "Add Platform" does the same."""
    a = asc.app()
    if not a: sys.exit("no app record yet")
    existing = [v for v in asc.versions(a["id"]) if v["attributes"]["platform"] == "IOS"]
    if existing:
        at = existing[0]["attributes"]
        print(f"iOS platform already present: version {at['versionString']} · {at['appStoreState']}")
        return
    version = project_version()
    r = asc.s.post(API + "/v1/appStoreVersions", json={"data": {"type": "appStoreVersions",
        "attributes": {"platform": "IOS", "versionString": version},
        "relationships": {"app": {"data": {"type": "apps", "id": a["id"]}}}}}, timeout=30)
    if r.status_code >= 400:
        errs = r.json().get("errors", [{}]) if r.content else [{}]
        detail = "; ".join(f"{e.get('code', '')}: {e.get('detail', e.get('title', ''))}" for e in errs)
        sys.exit(f"Apple refused to add iOS ({version}): HTTP {r.status_code}: {detail[:500]}\n"
                 "Add it in App Store Connect: open the app, click the + next to the platform list, choose iOS (Add Platform).")
    print(f"added iOS platform, version {version}")

def make_profile(asc, identifier, PROFILE, ptype="TVOS_APP_STORE"):
    b = asc.bundle(identifier)
    if not b: sys.exit(f"register {identifier} first: uv run scripts/asc.py bundle-id")
    certs = [c for c in asc.get("/v1/certificates", limit=50)["data"]
             if c["attributes"]["certificateType"] in ("DISTRIBUTION", "IOS_DISTRIBUTION")]
    if not certs: sys.exit("no distribution certificate on the team")
    for old in asc.get("/v1/profiles", **{"filter[name]": PROFILE})["data"]:
        gone = asc.s.delete(API + f"/v1/profiles/{old['id']}", timeout=30)
        if gone.status_code not in (200, 204, 404):
            sys.exit(f"could not delete old profile {old['id']}: HTTP {gone.status_code} {gone.text[:200]}")
    made = asc.post("/v1/profiles", {"data": {"type": "profiles",
        "attributes": {"name": PROFILE, "profileType": ptype},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": b["id"]}},
            "certificates": {"data": [{"type": "certificates", "id": c["id"]} for c in certs]}}}})["data"]
    import base64
    content = base64.b64decode(made["attributes"]["profileContent"])
    uuid = made["attributes"]["uuid"]
    for folder in ("~/Library/MobileDevice/Provisioning Profiles", "~/Library/Developer/Xcode/UserData/Provisioning Profiles"):
        d = Path(folder).expanduser()
        d.mkdir(parents=True, exist_ok=True)
        (d / f"{uuid}.mobileprovision").write_bytes(content)
    print(f"profile '{PROFILE}' installed ({len(certs)} certificate(s), expires {made['attributes']['expirationDate'][:10]})")

def group(asc):
    GROUP = env().get("ASC_BETA_GROUP") or "Internal"
    a = asc.app()
    if not a: sys.exit("no app record yet: create it in App Store Connect first")
    g = next((g for g in asc.groups(a["id"]) if g["attributes"]["name"] == GROUP), None)
    if not g:
        g = asc.post("/v1/betaGroups", {"data": {"type": "betaGroups",
            "attributes": {"name": GROUP, "isInternalGroup": True, "hasAccessToAllBuilds": True},
            "relationships": {"app": {"data": {"type": "apps", "id": a["id"]}}}}})["data"]
        print("created group", GROUP)
    # Internal testers are team members: add each one (by id, no addresses printed).
    users = asc.get("/v1/users", limit=50)["data"]
    added = 0
    for u in users:
        at = u["attributes"]
        r = asc.s.post(API + "/v1/betaTesters", json={"data": {"type": "betaTesters",
            "attributes": {"email": at["username"], "firstName": at.get("firstName", ""), "lastName": at.get("lastName", "")},
            "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": g["id"]}]}}}}, timeout=30)
        if r.status_code < 300: added += 1
        elif r.status_code != 409: print(f"tester {at.get('firstName', '?')}: HTTP {r.status_code}")
    print(f"group {GROUP}: {added} team member(s) added")

LISTING = Path(__file__).resolve().parent.parent / "docs/appstore/listing.json"
PLATFORMS = ("TV_OS", "IOS")

def listing(asc):
    """Make App Store Connect match docs/appstore/listing.json. Without --apply, only
    prints what differs. Editable only while a version is unsubmitted. Price,
    availability, App Privacy, age rating and the review contact stay web-UI steps
    (docs/appstore/README.md)."""
    apply = "--apply" in sys.argv
    want = json.loads(LISTING.read_text())
    a = asc.app()
    if not a: sys.exit("no app record yet")
    changes = 0

    def sync(label, path, rtype, rid, have, desired, create=None):
        nonlocal changes
        diff = {k: v for k, v in desired.items() if (have or {}).get(k) != v}
        if not diff: print(f"= {label}"); return
        changes += 1
        print(f"~ {label}: {', '.join(diff)}")
        if not apply: return
        if rid is None:
            asc.post(path, {"data": {"type": rtype, "attributes": desired, "relationships": create}})
        else:
            asc.patch(f"{path}/{rid}", {"data": {"type": rtype, "id": rid, "attributes": diff}})

    info = next(i for i in asc.get(f"/v1/apps/{a['id']}/appInfos")["data"]
                if i["attributes"]["state"] != "READY_FOR_DISTRIBUTION")
    have_info = {l["attributes"]["locale"]: l for l in asc.get(f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]}
    for locale, text in want["locales"].items():
        cur = have_info.get(locale)
        sync(f"app info {locale}", "/v1/appInfoLocalizations", "appInfoLocalizations", cur and cur["id"],
             cur and cur["attributes"], {"name": text["name"], "subtitle": text["subtitle"], "privacyPolicyUrl": want["privacyPolicyUrl"]}
             | ({} if cur else {"locale": locale}),
             {"appInfo": {"data": {"type": "appInfos", "id": info["id"]}}})

    cats = asc.get(f"/v1/appInfos/{info['id']}", include="primaryCategory,secondaryCategory")["data"]["relationships"]
    cur_cats = (cats["primaryCategory"]["data"] or {}).get("id"), (cats["secondaryCategory"]["data"] or {}).get("id")
    if cur_cats == (want["primaryCategory"], want["secondaryCategory"]): print("= categories")
    else:
        changes += 1
        print(f"~ categories: {cur_cats} -> {want['primaryCategory']}, {want['secondaryCategory']}")
        if apply:
            asc.patch(f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
                "primaryCategory": {"data": {"type": "appCategories", "id": want["primaryCategory"]}},
                "secondaryCategory": {"data": {"type": "appCategories", "id": want["secondaryCategory"]}}}}})

    for v in asc.versions(a["id"]):
        at = v["attributes"]
        if at["platform"] not in PLATFORMS or at["appStoreState"] not in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
            continue
        p = at["platform"]
        sync(f"{p} version", "/v1/appStoreVersions", "appStoreVersions", v["id"], at,
             {"versionString": want["versionString"], "copyright": want["copyright"]})
        have_loc = {l["attributes"]["locale"]: l for l in asc.get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]}
        for locale, text in want["locales"].items():
            cur = have_loc.get(locale)
            desired = {k: text[k] for k in ("description", "keywords", "promotionalText")} | {
                "supportUrl": want["supportUrl"], "marketingUrl": want["marketingUrl"]}
            sync(f"{p} {locale}", "/v1/appStoreVersionLocalizations", "appStoreVersionLocalizations", cur and cur["id"],
                 cur and cur["attributes"], desired | ({} if cur else {"locale": locale}),
                 {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}})
        review = asc.s.get(API + f"/v1/appStoreVersions/{v['id']}/appStoreReviewDetail", timeout=30)
        cur = review.json().get("data") if review.status_code == 200 else None
        # Apple refuses review notes without the review contact (name, email, phone): a web-UI step.
        if not (cur and cur["attributes"].get("contactEmail")):
            print(f"! {p} review notes: skipped until the App Review contact is filled in (App Store Connect, App Review Information)")
            changes += 1
            continue
        sync(f"{p} review notes", "/v1/appStoreReviewDetails", "appStoreReviewDetails", cur and cur["id"],
             cur and cur["attributes"], want["review"],
             {"appStoreVersion": {"data": {"type": "appStoreVersions", "id": v["id"]}}})
    print(f"{changes} difference(s)" + ("" if apply or not changes else "; run with --apply to write them"))

# Screenshot sets: which display type each folder fills; the first type Apple accepts wins. The 6.9" iPhone
# shots (1320 x 2868) go in APP_IPHONE_67: the API refused APP_IPHONE_69 (409, 2026-11-25).
SHOT_SETS = {"TV_OS": [("tv", ["APP_APPLE_TV"])],
             "IOS": [("iphone", ["APP_IPHONE_67", "APP_IPHONE_69"]), ("ipad", ["APP_IPAD_PRO_3GEN_129"])]}

def screenshots(asc):
    """Replace each version's screenshots with the PNGs scripts/screenshots.sh made. Without --apply,
    only says what would be uploaded. A set is emptied and refilled in file order, so a rerun is safe."""
    apply = "--apply" in sys.argv
    args = [x for x in sys.argv[2:] if not x.startswith("--")]
    root = Path(args[0] if args else Path(__file__).resolve().parent.parent / "build/screenshots")
    a = asc.app()
    if not a: sys.exit("no app record yet")
    failed = False
    for v in asc.versions(a["id"]):
        at = v["attributes"]
        if at["platform"] not in SHOT_SETS or at["appStoreState"] not in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED"):
            continue
        p = at["platform"]
        locs = {l["attributes"]["locale"]: l["id"] for l in asc.get(f"/v1/appStoreVersions/{v['id']}/appStoreVersionLocalizations")["data"]}
        for locale, loc_id in sorted(locs.items()):
            have = {x["attributes"]["screenshotDisplayType"]: x for x in asc.get(f"/v1/appStoreVersionLocalizations/{loc_id}/appScreenshotSets")["data"]}
            for folder, types in SHOT_SETS[p]:
                files = sorted((root / locale / folder).glob("*.png"))
                if not files:
                    print(f"! {p} {locale} {folder}: no PNGs in {root / locale / folder}"); continue
                current = next((have[t] for t in types if t in have), None)
                print(f"~ {p} {locale} {folder}: {len(files)} shot(s) -> {current['attributes']['screenshotDisplayType'] if current else types[0]}"
                      + ("" if apply else " (dry run)"))
                if not apply: continue
                # A fresh token per set: the JWT lasts 15 minutes and each set may wait 5 for processing.
                asc.s.headers["Authorization"] = "Bearer " + token(env())
                if current is None:
                    for t in types:
                        r = asc.s.post(API + "/v1/appScreenshotSets", json={"data": {"type": "appScreenshotSets",
                            "attributes": {"screenshotDisplayType": t},
                            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc_id}}}}}, timeout=30)
                        if r.status_code < 400: current = r.json()["data"]; break
                        print(f"  {t} refused ({r.status_code}), trying the next type")
                    if current is None: sys.exit(f"{p} {locale} {folder}: Apple took none of {types}")
                set_id = current["id"]
                old = asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]
                def drop(shots):
                    for x in shots:
                        r = asc.s.delete(API + f"/v1/appScreenshots/{x['id']}", timeout=30)
                        if r.status_code >= 400: sys.exit(f"delete {x['id']}: HTTP {r.status_code}")
                # Old shots go after the new ones are in, so a failed run never leaves the set empty;
                # a set holds 10 at most, so when both don't fit the old ones go first.
                late = len(old) + len(files) <= 10
                if not late: drop(old)
                new_ids = []
                for f in files:
                    data = f.read_bytes()
                    shot = asc.post("/v1/appScreenshots", {"data": {"type": "appScreenshots",
                        "attributes": {"fileName": f.name, "fileSize": len(data)},
                        "relationships": {"appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": set_id}}}}})["data"]
                    for op in shot["attributes"]["uploadOperations"]:
                        part = data[op["offset"]:op["offset"] + op["length"]]
                        headers = {h["name"]: h["value"] for h in op.get("requestHeaders", [])}
                        r = requests.request(op["method"], op["url"], data=part, headers=headers, timeout=120)
                        if r.status_code >= 400: sys.exit(f"{f.name}: upload part HTTP {r.status_code}")
                    asc.patch(f"/v1/appScreenshots/{shot['id']}", {"data": {"type": "appScreenshots", "id": shot["id"],
                        "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}})
                    new_ids.append(shot["id"])
                    print(f"  uploaded {f.name}")
                if late: drop(old)
                # Display order is file order, said outright rather than left to creation order.
                r = asc.s.patch(API + f"/v1/appScreenshotSets/{set_id}/relationships/appScreenshots",
                                json={"data": [{"type": "appScreenshots", "id": i} for i in new_ids]}, timeout=30)
                if r.status_code >= 400: sys.exit(f"{p} {locale} {folder}: ordering HTTP {r.status_code}")
                # Apple processes the images after the commit: wait, so a refusal (wrong size) is seen here.
                for _ in range(60):
                    states = [x["attributes"]["assetDeliveryState"]["state"] for x in asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]]
                    if all(st in ("COMPLETE", "FAILED") for st in states): break
                    time.sleep(5)
                bad = [x for x in asc.get(f"/v1/appScreenshotSets/{set_id}/appScreenshots")["data"]
                       if x["attributes"]["assetDeliveryState"]["state"] != "COMPLETE"]
                for x in bad:
                    errs = x["attributes"]["assetDeliveryState"].get("errors") or []
                    print(f"  ! {x['attributes']['fileName']}: {x['attributes']['assetDeliveryState']['state']} {'; '.join(e.get('description', '') for e in errs)}")
                if not bad: print(f"  = {len(files)} processed")
                failed = failed or bool(bad)
    if failed: sys.exit("some screenshots were refused or still processing; see the ! lines")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    asc = ASC()
    {"status": status, "bundle-id": bundle_id, "group": group, "builds": builds, "profile": profile, "add-ios": add_ios, "listing": listing, "screenshots": screenshots}.get(cmd, lambda _: sys.exit(__doc__))(asc)
