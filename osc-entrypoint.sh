#!/usr/bin/env bash
# OSC entrypoint for OpenBao: single-node Raft storage on a persistent volume,
# static-key auto-unseal, TLS terminated by the OSC ingress. Writes the server
# config through upstream's BAO_LOCAL_CONFIG, then hands over to upstream's
# docker-entrypoint.sh (which chowns its own dirs and drops root via su-exec).
set -Eeuo pipefail

: "${BAO_STATIC_SEAL_KEY:?BAO_STATIC_SEAL_KEY (32-byte unseal key, hex or base64) is required}"

PORT="${PORT:-8080}"
DATA_DIR="${BAO_DATA_DIR:-/data}"
LOG_LEVEL="${BAO_LOG_LEVEL:-info}"

if [[ -n "${OSC_HOSTNAME:-}" ]]; then
  API_ADDR="https://${OSC_HOSTNAME}"
else
  API_ADDR="http://127.0.0.1:${PORT}"
fi

# Volume may be root-owned; make it writable for the openbao user.
mkdir -p "${DATA_DIR}/raft"
if [[ "$(id -u)" == "0" ]]; then
  chown -R openbao:openbao "${DATA_DIR}"
fi

# The unseal key is referenced via env://, it is never written to the config file.
export BAO_LOCAL_CONFIG="$(cat <<JSON
{
  "ui": true,
  "disable_mlock": true,
  "log_level": "${LOG_LEVEL}",
  "api_addr": "${API_ADDR}",
  "cluster_addr": "http://127.0.0.1:8201",
  "listener": [{ "tcp": { "address": "0.0.0.0:${PORT}", "tls_disable": true } }],
  "storage": { "raft": { "path": "${DATA_DIR}/raft", "node_id": "osc-node-1" } },
  "seal": { "static": { "current_key_id": "osc-1", "current_key": "env://BAO_STATIC_SEAL_KEY" } }
}
JSON
)"

exec docker-entrypoint.sh "$@"
