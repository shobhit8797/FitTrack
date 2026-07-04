#!/usr/bin/env python3
"""App Store Connect build queries for FitTrack.

Default: print the highest uploaded build number (used by sign_and_build.sh
to auto-bump). With --list: print the 3 most recent builds + processing state.

Requires PyJWT + cryptography:  python3 -m pip install --user PyJWT cryptography
"""
import json
import os
import sys
import time
import urllib.request

import jwt

KEY_ID = 'GQ653NHYST'
ISSUER_ID = '263d00d5-4518-4789-886d-018f6c735afe'
APP_ID = '6785555577'
KEY_PATH = os.path.expanduser(f'~/.appstoreconnect/private_keys/AuthKey_{KEY_ID}.p8')


def _token() -> str:
    with open(KEY_PATH) as f:
        key = f.read()
    return jwt.encode(
        {'iss': ISSUER_ID, 'iat': int(time.time()), 'exp': int(time.time()) + 1200,
         'aud': 'appstoreconnect-v1'},
        key, algorithm='ES256', headers={'kid': KEY_ID})


def _builds(limit: int) -> list:
    url = (f'https://api.appstoreconnect.apple.com/v1/builds?filter[app]={APP_ID}'
           f'&sort=-uploadedDate&limit={limit}'
           f'&fields[builds]=version,uploadedDate,processingState')
    req = urllib.request.Request(url, headers={'Authorization': f'Bearer {_token()}'})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.loads(r.read())['data']


if __name__ == '__main__':
    if '--list' in sys.argv:
        for b in _builds(3):
            a = b['attributes']
            print(f"Build {a['version']:>4} | {a['processingState']:<12} | {a['uploadedDate']}")
    else:
        versions = [int(b['attributes']['version']) for b in _builds(10)
                    if b['attributes']['version'].isdigit()]
        print(max(versions, default=0))
