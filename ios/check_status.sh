#!/bin/bash
# TestFlight processing status for the last 3 uploaded builds.
DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
source "$DIR/python_env.sh"
exec "$ASC_PYTHON" "$DIR/asc_builds.py" --list
