#!/usr/bin/env bash
# Fetch the pinned third-party sources into ref/ (untouched upstream copies).
# Nothing here is run automatically; invoke via `make fetch`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/ref"
cd "$ROOT/ref"

clone_at() {  # url dir commit
  local url=$1 dir=$2 commit=$3
  if [ -d "$dir/.git" ]; then
    echo "[skip] $dir already present"
  else
    git clone "$url" "$dir"
  fi
  git -C "$dir" checkout --quiet "$commit"
  echo "[ok]   $dir @ $commit"
}

# Official C reference. Dumbo v2 = crypto_aead/elephant160v2/ref/
clone_at https://github.com/TimBeyne/Elephant       Elephant       b1a6883
# GMU RTL baseline (implements Elephant v1!). src_rtl/v1..v4
clone_at https://github.com/GMUCERG/Elephant        GMU-Elephant   090d1e7
# GMU LWC development package: provides cryptotvgen (software/cryptotvgen), v1.2.0
clone_at https://github.com/GMUCERG/LWC             LWC            9232d6d
# Independent C implementation for cross-checking
# clone_at https://github.com/rweather/lwc-finalists  lwc-finalists  77b23e6

# v2 encrypt.c includes crypto_aead.h, which is missing upstream: add an empty stub.
STUB="Elephant/crypto_aead/elephant160v2/ref/crypto_aead.h"
[ -f "$STUB" ] || { : > "$STUB"; echo "[ok]   created empty stub $STUB"; }
