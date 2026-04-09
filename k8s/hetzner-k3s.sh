#!/usr/bin/env bash
# Wrapper for hetzner-k3s on NixOS.
# Sets SSL_CERT_FILE and ZONEINFO which the statically-compiled Crystal binary
# cannot find on its own because NixOS doesn't use standard FHS paths.
set -euo pipefail

if [[ "$(uname)" == "Darwin" ]]; then
  export SSL_CERT_FILE=/etc/ssl/cert.pem
else
  export SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
fi
export ZONEINFO=$(nix-build '<nixpkgs>' -A tzdata --no-out-link 2>/dev/null)/share/zoneinfo

exec hetzner-k3s "$@"
