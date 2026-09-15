#!/usr/bin/env bash
# Download (or create) the iOS development profiles for the app and the
# share extension through the App Store Connect API and install them where
# Xcode looks.
#
# Why this exists: the App Group entitlement needs explicit profiles, and on
# a Mac with no Apple ID in Xcode automatic signing cannot make them. The
# API can. Run once per Mac, and again after adding a device or certificate
# (delete the profile in the developer portal first so it is recreated).
#
# Usage: scripts/dev-profiles.sh
set -euo pipefail
cd "$(dirname "$0")/.."

KEY_ID="${ASC_API_KEY_ID:-8BTRQ6P2YQ}"
ISSUER_ID="${ASC_ISSUER_ID:-d543c968-1d53-4a5c-b447-7470b4c36505}"
KEY_PATH="$HOME/.appstoreconnect/private_keys/AuthKey_${KEY_ID}.p8"
[ -f "$KEY_PATH" ] || { echo "✗ API key not found at $KEY_PATH"; exit 1; }

python3 - "$KEY_ID" "$ISSUER_ID" "$KEY_PATH" <<'PY'
import sys, json, time, base64, pathlib, subprocess, plistlib, urllib.request
key_id, issuer, key_path = sys.argv[1:4]
try:
    import jwt
except ImportError:
    sys.exit("✗ pip install pyjwt cryptography")

now = int(time.time())
token = jwt.encode({"iss": issuer, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
                   pathlib.Path(key_path).read_text(), algorithm="ES256", headers={"kid": key_id})
API = "https://api.appstoreconnect.apple.com/v1"

def call(method, path, body=None):
    req = urllib.request.Request(API + path, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)

PROFILES = {
    "SwimSync Mobile Development": "com.osamabedier.SwimSyncMobile",
    "SwimSync Share Development": "com.osamabedier.SwimSyncMobile.Share",
}
bundle_ids = {b["attributes"]["identifier"]: b["id"] for b in call("GET", "/bundleIds?limit=200")["data"]}
certs = [c["id"] for c in call("GET", "/certificates?filter[certificateType]=DEVELOPMENT&limit=50")["data"]]
devices = [d["id"] for d in call("GET", "/devices?filter[platform]=IOS&filter[status]=ENABLED&limit=100")["data"]
           if d["attributes"].get("deviceClass") in ("IPHONE", "IPAD")]
existing = {p["attributes"]["name"]: p for p in call("GET", "/profiles?filter[profileType]=IOS_APP_DEVELOPMENT&limit=200")["data"]}
out_dir = pathlib.Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
out_dir.mkdir(parents=True, exist_ok=True)

for name, bundle in PROFILES.items():
    profile = existing.get(name)
    if profile is None or profile["attributes"]["profileState"] != "ACTIVE":
        if profile is not None:
            call("DELETE", f"/profiles/{profile['id']}")
        profile = call("POST", "/profiles", {"data": {"type": "profiles",
            "attributes": {"name": name, "profileType": "IOS_APP_DEVELOPMENT"},
            "relationships": {
                "bundleId": {"data": {"type": "bundleIds", "id": bundle_ids[bundle]}},
                "certificates": {"data": [{"type": "certificates", "id": c} for c in certs]},
                "devices": {"data": [{"type": "devices", "id": d} for d in devices]}}}})["data"]
        print(f"→ created {name}")
    raw = base64.b64decode(profile["attributes"]["profileContent"])
    plist = plistlib.loads(subprocess.run(["security", "cms", "-D"], input=raw, capture_output=True, check=True).stdout)
    (out_dir / f"{plist['UUID']}.mobileprovision").write_bytes(raw)
    print(f"✓ {name}: {plist['UUID']} ({len(plist.get('ProvisionedDevices', []))} devices)")
PY
