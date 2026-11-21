#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Offline-only CLI tests: must fail before any SSH connection is made.
bash bootstrap.sh --help | grep -q -- '--protocol xray|amnezia|both'
if bash bootstrap.sh --server '../bad' --protocol xray > /dev/null 2>&1; then
    echo "ERROR: invalid server was accepted" >&2
    exit 1
fi
if bash bootstrap.sh --server 203.0.113.20 --protocol invalid > /dev/null 2>&1; then
    echo "ERROR: invalid protocol was accepted" >&2
    exit 1
fi
if bash bootstrap.sh --server 203.0.113.20 --protocol xray \
    --admin-key /this/key/does/not/exist \
    --admin-pubkey /this/public/key/does/not/exist \
    --xray-pubkey /this/xray/key/does/not/exist > /dev/null 2>&1; then
    echo "ERROR: missing keys were accepted" >&2
    exit 1
fi
echo "Offline bootstrap guard checks passed."
