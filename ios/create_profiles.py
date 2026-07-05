#!/usr/bin/env python3
"""Create & install the App Store distribution provisioning profiles FitTrack
needs for a release build — one for the app, one for the widget extension.

The release archive signs *manually* (see project.yml `configs: Release`) because
headless auto-signing (`-allowProvisioningUpdates` + API key) cannot create a
profile for the widget's bundle ID. This script pre-creates both profiles via the
App Store Connect API and drops them in ~/Library/MobileDevice/Provisioning Profiles.

Run it once per machine, or whenever the profiles are missing/expired:
    python3 ios/create_profiles.py

Prereqs: PyJWT + cryptography (`python3 -m pip install --user PyJWT cryptography`),
the API key at ~/.appstoreconnect/private_keys/AuthKey_GQ653NHYST.p8, and the two
App IDs (com.shobhit.fittrack, com.shobhit.fittrack.Widgets) + the App Group
group.com.shobhit.fittrack registered in the Developer portal with the App Groups
capability assigned to BOTH App IDs. (App Group assignment is portal-only — the
ASC API has no App Groups endpoint.)

Profile NAMES are what project.yml/ExportOptions.plist reference — keep them stable:
    "FitTrack App Store"          -> com.shobhit.fittrack
    "FitTrack Widgets App Store"  -> com.shobhit.fittrack.Widgets
"""
import base64
import json
import os
import plistlib
import sys
import time
import urllib.error
import urllib.request

import jwt

KEY_ID = 'GQ653NHYST'
ISSUER_ID = '263d00d5-4518-4789-886d-018f6c735afe'
KEY_PATH = os.path.expanduser(f'~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8')
PROFILE_DIR = os.path.expanduser('~/Library/MobileDevice/Provisioning Profiles')

# profile name -> bundle identifier
PROFILES = {
    'FitTrack App Store': 'com.shobhit.fittrack',
    'FitTrack Widgets App Store': 'com.shobhit.fittrack.Widgets',
}


def _token() -> str:
    return jwt.encode(
        {'iss': ISSUER_ID, 'iat': int(time.time()), 'exp': int(time.time()) + 1200,
         'aud': 'appstoreconnect-v1'},
        open(KEY_PATH).read(), algorithm='ES256', headers={'kid': KEY_ID})


def _api(method: str, url: str, body=None):
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        url, data=data, method=method,
        headers={'Authorization': f'Bearer {_token()}', 'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()


def main() -> int:
    _, certs = _api('GET', 'https://api.appstoreconnect.apple.com/v1/certificates'
                           '?limit=200&fields[certificates]=certificateType,expirationDate')
    dist = next((c['id'] for c in certs.get('data', [])
                 if c['attributes']['certificateType'] == 'DISTRIBUTION'), None)
    if not dist:
        print('ERROR: no DISTRIBUTION certificate found for this account.')
        return 1

    _, bids = _api('GET', 'https://api.appstoreconnect.apple.com/v1/bundleIds'
                          '?limit=200&fields[bundleIds]=identifier')
    bid_by_ident = {b['attributes']['identifier']: b['id'] for b in bids.get('data', [])}

    _, profs = _api('GET', 'https://api.appstoreconnect.apple.com/v1/profiles'
                           '?limit=200&fields[profiles]=name')
    existing = {p['attributes']['name']: p['id'] for p in profs.get('data', [])}

    os.makedirs(PROFILE_DIR, exist_ok=True)
    rc = 0
    for name, ident in PROFILES.items():
        bundle_id = bid_by_ident.get(ident)
        if not bundle_id:
            print(f"ERROR: bundle ID '{ident}' not registered in the portal — "
                  f"create it before running this.")
            rc = 1
            continue
        if name in existing:  # replace so cert/entitlement changes take effect
            _api('DELETE', f"https://api.appstoreconnect.apple.com/v1/profiles/{existing[name]}")
        body = {'data': {
            'type': 'profiles',
            'attributes': {'name': name, 'profileType': 'IOS_APP_STORE'},
            'relationships': {
                'bundleId': {'data': {'type': 'bundleIds', 'id': bundle_id}},
                'certificates': {'data': [{'type': 'certificates', 'id': dist}]}}}}
        st, d = _api('POST', 'https://api.appstoreconnect.apple.com/v1/profiles', body)
        if st not in (200, 201):
            print(f"CREATE FAILED '{name}' ({st}): {d}")
            rc = 1
            continue
        content = base64.b64decode(d['data']['attributes']['profileContent'])
        s, e = content.find(b'<?xml'), content.find(b'</plist>') + 8
        uuid = plistlib.loads(content[s:e])['UUID']
        path = os.path.join(PROFILE_DIR, f'{uuid}.mobileprovision')
        open(path, 'wb').write(content)
        print(f"installed '{name}' -> {ident}  ({uuid})")
    return rc


if __name__ == '__main__':
    sys.exit(main())
