#!/bin/bash
# Resolve the Python interpreter that has PyJWT + cryptography, and export it as
# $ASC_PYTHON. Sourced by check_status.sh, sign_and_build.sh, and create_profiles.
#
# Why this exists: the App Store Connect scripts need PyJWT to sign the API JWT.
# A bare `python3` is whatever happens to sit first on PATH, and that changes
# under you — installing any Homebrew formula that depends on python@3.x moves
# `python3` to a fresh interpreter with no packages, which silently breaks the
# build-number auto-bump and hard-fails check_status.sh.
#
# Preference order:
#   1. ios/.venv          — the project venv (create it with the command below)
#   2. python3 on PATH    — if it can import jwt
#   3. /usr/bin/python3   — the macOS system Python, where a `pip install --user`
#                           from an older setup may still live
#
# To create the venv (uv is the project's Python tool):
#   cd ios && uv venv .venv && uv pip install --python .venv/bin/python PyJWT cryptography

_ASC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_has_jwt() {
    [ -x "$1" ] && "$1" -c 'import jwt' >/dev/null 2>&1
}

ASC_PYTHON=""
for _candidate in "$_ASC_DIR/.venv/bin/python" "$(command -v python3)" /usr/bin/python3; do
    if _has_jwt "$_candidate"; then
        ASC_PYTHON="$_candidate"
        break
    fi
done

if [ -z "$ASC_PYTHON" ]; then
    # Leave it as plain python3 so the caller fails with the real ImportError
    # rather than a confusing "command not found".
    ASC_PYTHON="python3"
    echo "  WARNING: no Python with PyJWT found. Run:" >&2
    echo "    cd $_ASC_DIR && uv venv .venv && uv pip install --python .venv/bin/python PyJWT cryptography" >&2
fi

export ASC_PYTHON
