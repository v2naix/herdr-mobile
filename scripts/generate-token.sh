#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
TOKEN_FILE="${HERDR_MOBILE_TOKEN_FILE:-$PWD/.herdr-mobile-token}"
TOKEN_FILE="$TOKEN_FILE" .venv/bin/python - <<'PY'
import os
from pathlib import Path
from server.auth import load_or_create_token
path = Path(os.environ["TOKEN_FILE"])
token = load_or_create_token(path)
print(f"Token file: {path} (0600)")
print(token)
print("Treat this output as a password; paste it only into the herdr-mobile login screen.")
PY
