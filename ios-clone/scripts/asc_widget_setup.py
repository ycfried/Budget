#!/usr/bin/env python3
"""App Store Connect setup for the OnBudget widget (build 17).

Two subcommands, stdlib only (urllib + openssl for the ES256 JWT —
the same minting the upload workflow already inlines):

  setup        — create/find the widget bundle id (com.onbudget.ios.widget),
                 enable the App Groups capability on both App IDs, create/
                 find the App Group (group.com.onbudget.ios), link it to
                 both bundle ids, create/find the widget App Store profile
                 ("OnBudget Widget", reusing the distribution certificate
                 of the existing app profile), and download that profile.
                 Idempotent: every create is check-first, so re-runs are
                 safe. NEVER touches the existing app profile 83TZ7C4533
                 or any certificate — the archive step's
                 -allowProvisioningUpdates updates that profile in place
                 to add App Groups (same id, workflow untouched).
  export-plist — query the ACTIVE App Store profiles for the app and
                 widget bundle ids and write exportOptions.plist with
                 their real names (no guessing what Xcode named a profile).

Failure policy: bundle-id and profile operations fail hard (the
upload cannot proceed without them). Capability/group-linking
operations warn and continue — the archive's -allowProvisioningUpdates
is the backstop for those, and a wrong API shape there must not kill
an upload the archive could still save.

Secrets (key id / issuer / .p8 path) arrive as argv, are never
printed, and are never written anywhere except the JWT in memory.
"""
import argparse
import base64
import json
import os
import plistlib
import subprocess
import sys
import time
import urllib.error
import urllib.request

API = "https://api.appstoreconnect.apple.com"
APP_BUNDLE_ID = "com.onbudget.ios"
WIDGET_BUNDLE_ID = "com.onbudget.ios.widget"
APP_BUNDLE_RESOURCE_ID = "MZ58SJMG6V"
APP_PROFILE_ID = "83TZ7C4533"
GROUP_ID = "group.com.onbudget.ios"
WIDGET_PROFILE_NAME = "OnBudget Widget"


def b64u(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def mint_jwt(key_id: str, issuer: str, key_path: str) -> str:
    now = int(time.time())
    header = b64u(json.dumps(
        {"alg": "ES256", "kid": key_id, "typ": "JWT"},
        separators=(",", ":")).encode())
    payload = b64u(json.dumps(
        {"iss": issuer, "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"},
        separators=(",", ":")).encode())
    msg = ("%s.%s" % (header, payload)).encode()
    der = subprocess.run(
        ["openssl", "dgst", "-sha256", "-sign", key_path],
        input=msg, capture_output=True, check=True).stdout
    i = 2
    assert der[i] == 0x02
    i += 1
    len_r = der[i]
    i += 1
    r = der[i:i + len_r]
    i += len_r
    assert der[i] == 0x02
    i += 1
    len_s = der[i]
    i += 1
    s = der[i:i + len_s]
    r = r.lstrip(b"\x00").rjust(32, b"\x00")
    s = s.lstrip(b"\x00").rjust(32, b"\x00")
    return "%s.%s.%s" % (header, payload, b64u(r + s))


class ASC:
    def __init__(self, token: str):
        self.token = token

    def call(self, method: str, path: str, body=None):
        req = urllib.request.Request(
            API + path,
            method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={
                "Authorization": "Bearer " + self.token,
                "Content-Type": "application/json",
                "Accept": "application/json",
            })
        try:
            with urllib.request.urlopen(req) as resp:
                return json.loads(resp.read() or b"{}")
        except urllib.error.HTTPError as e:
            detail = e.read().decode(errors="replace")
            raise RuntimeError(f"{method} {path} -> HTTP {e.code}: {detail}") from e

    def get(self, path: str):
        return self.call("GET", path)

    def post(self, path: str, body):
        return self.call("POST", path, body)

    def patch(self, path: str, body):
        return self.call("PATCH", path, body)


def find_bundle_id(asc: ASC, identifier: str):
    data = asc.get(f"/v1/bundleIds?filter[identifier]={identifier}&limit=1")
    items = data.get("data", [])
    return items[0]["id"] if items else None


def ensure_bundle_id(asc: ASC, identifier: str, name: str) -> str:
    existing = find_bundle_id(asc, identifier)
    if existing:
        print(f"bundle id {identifier} already exists ({existing})")
        return existing
    created = asc.post("/v1/bundleIds", {"data": {
        "type": "bundleIds",
        "attributes": {
            "identifier": identifier, "name": name, "platform": "IOS",
        }}})
    new_id = created["data"]["id"]
    print(f"created bundle id {identifier} ({new_id})")
    return new_id


def ensure_app_groups_capability(asc: ASC, resource_id: str, identifier: str):
    """Enable APPLICATION_GROUPS on a bundle id. Warn-and-continue on
    failure: the archive's -allowProvisioningUpdates is the backstop."""
    try:
        current = asc.get(f"/v1/bundleIds/{resource_id}")
        caps = current["data"]["attributes"].get("capabilities", [])
        if any(c.get("capabilityType") == "APPLICATION_GROUPS" for c in caps):
            print(f"{identifier}: App Groups capability already enabled")
            return
        caps = list(caps) + [{"capabilityType": "APPLICATION_GROUPS", "settings": []}]
        asc.patch(f"/v1/bundleIds/{resource_id}", {"data": {
            "type": "bundleIds", "id": resource_id,
            "attributes": {"capabilities": caps}}})
        print(f"{identifier}: App Groups capability enabled")
    except Exception as e:  # noqa: BLE001 — backstop is the archive step
        print(f"WARNING: could not enable App Groups on {identifier}: {e}")
        print("WARNING: continuing — the archive step may enable it via "
              "-allowProvisioningUpdates")


def ensure_app_group(asc: ASC, widget_resource_id: str):
    """Create/find the App Group, link it to both bundle ids.
    Warn-and-continue on failure (archive backstop). Returns group id
    or None."""
    try:
        found = asc.get(f"/v1/appGroups?filter[identifier]={GROUP_ID}&limit=1")
        items = found.get("data", [])
        if items:
            group_resource_id = items[0]["id"]
            print(f"app group {GROUP_ID} already exists ({group_resource_id})")
        else:
            created = asc.post("/v1/appGroups", {"data": {
                "type": "appGroups",
                "attributes": {"identifier": GROUP_ID}}})
            group_resource_id = created["data"]["id"]
            print(f"created app group {GROUP_ID} ({group_resource_id})")
        for resource_id, identifier in (
                (APP_BUNDLE_RESOURCE_ID, APP_BUNDLE_ID),
                (widget_resource_id, WIDGET_BUNDLE_ID)):
            linked = asc.get(f"/v1/bundleIds/{resource_id}/relationships/appGroups")
            if any(d["id"] == group_resource_id for d in linked.get("data", [])):
                print(f"{identifier}: app group already linked")
                continue
            asc.post(f"/v1/bundleIds/{resource_id}/relationships/appGroups",
                     {"data": [{"type": "appGroups", "id": group_resource_id}]})
            print(f"{identifier}: app group linked")
        return group_resource_id
    except Exception as e:  # noqa: BLE001 — backstop is the archive step
        print(f"WARNING: app-group setup failed: {e}")
        print("WARNING: continuing — the archive step may create/link it "
              "via -allowProvisioningUpdates")
        return None


def distribution_cert_id(asc: ASC) -> str:
    profile = asc.get(f"/v1/profiles/{APP_PROFILE_ID}?include=certificates")
    certs = profile["data"]["relationships"]["certificates"]["data"]
    assert certs, "existing app profile has no certificates"
    return certs[0]["id"]


def active_store_profile(asc: ASC, bundle_resource_id: str):
    data = asc.get(
        f"/v1/profiles?filter[bundleId]={bundle_resource_id}"
        "&filter[profileType]=IOS_APP_STORE&limit=10")
    active = [p for p in data.get("data", [])
              if p["attributes"].get("status") == "ACTIVE"]
    if not active:
        return None
    active.sort(key=lambda p: p["attributes"].get("createdDate", ""))
    return active[-1]


def ensure_widget_profile(asc: ASC, widget_resource_id: str) -> str:
    existing = active_store_profile(asc, widget_resource_id)
    if existing:
        print(f"widget profile already exists: "
              f"{existing['attributes']['name']} ({existing['id']})")
        return existing["id"]
    cert_id = distribution_cert_id(asc)
    created = asc.post("/v1/profiles", {"data": {
        "type": "profiles",
        "attributes": {"name": WIDGET_PROFILE_NAME, "profileType": "IOS_APP_STORE"},
        "relationships": {
            "bundleId": {"data": {"type": "bundleIds", "id": widget_resource_id}},
            "certificates": {"data": [{"type": "certificates", "id": cert_id}]},
        }}})
    new_id = created["data"]["id"]
    print(f"created widget profile {WIDGET_PROFILE_NAME} ({new_id})")
    return new_id


def download_profile(asc: ASC, profile_id: str, dest_dir: str, filename: str):
    data = asc.get(f"/v1/profiles/{profile_id}")
    content = base64.b64decode(data["data"]["attributes"]["profileContent"])
    os.makedirs(dest_dir, exist_ok=True)
    path = os.path.join(dest_dir, filename)
    with open(path, "wb") as f:
        f.write(content)
    print(f"downloaded profile {profile_id} -> {path}")


def cmd_setup(args) -> int:
    token = mint_jwt(args.key_id, args.issuer, args.key_path)
    asc = ASC(token)
    widget_resource_id = ensure_bundle_id(asc, WIDGET_BUNDLE_ID, "OnBudget Widget")
    # Capabilities BEFORE the profile is created, so the profile
    # includes App Groups from the start.
    ensure_app_groups_capability(asc, APP_BUNDLE_RESOURCE_ID, APP_BUNDLE_ID)
    ensure_app_groups_capability(asc, widget_resource_id, WIDGET_BUNDLE_ID)
    ensure_app_group(asc, widget_resource_id)
    widget_profile_id = ensure_widget_profile(asc, widget_resource_id)
    download_profile(asc, widget_profile_id, args.profiles_dir,
                     "OnBudget_Widget.mobileprovision")
    print(json.dumps({
        "widget_bundle_resource_id": widget_resource_id,
        "widget_profile_id": widget_profile_id,
    }))
    return 0


def cmd_export_plist(args) -> int:
    token = mint_jwt(args.key_id, args.issuer, args.key_path)
    asc = ASC(token)
    widget_resource_id = find_bundle_id(asc, WIDGET_BUNDLE_ID)
    assert widget_resource_id, "widget bundle id not found — run setup first"
    mapping = {}
    for resource_id, bundle_id in (
            (APP_BUNDLE_RESOURCE_ID, APP_BUNDLE_ID),
            (widget_resource_id, WIDGET_BUNDLE_ID)):
        profile = active_store_profile(asc, resource_id)
        assert profile, f"no ACTIVE App Store profile for {bundle_id}"
        mapping[bundle_id] = profile["attributes"]["name"]
        print(f"{bundle_id} -> {mapping[bundle_id]} ({profile['id']})")
    plist = {
        "method": "app-store-connect",
        "signingStyle": "manual",
        "provisioningProfiles": mapping,
        "stripSwiftSymbols": True,
    }
    with open(args.out, "wb") as f:
        plistlib.dump(plist, f, fmt=plistlib.FMT_XML)
    print(f"wrote {args.out}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--key-id", required=True)
    parser.add_argument("--issuer", required=True)
    parser.add_argument("--key-path", required=True)
    sub = parser.add_subparsers(dest="command", required=True)
    setup = sub.add_parser("setup")
    setup.add_argument("--profiles-dir", required=True)
    export = sub.add_parser("export-plist")
    export.add_argument("--out", required=True)
    args = parser.parse_args()
    if args.command == "setup":
        return cmd_setup(args)
    return cmd_export_plist(args)


if __name__ == "__main__":
    sys.exit(main())
