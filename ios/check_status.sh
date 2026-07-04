#!/bin/bash
# TestFlight processing status for the last 3 uploaded builds.
exec python3 "$(cd "$(dirname "$0")" && pwd)/asc_builds.py" --list
