#!/usr/bin/env bash
# OSC entrypoint for OpenBao: single-node Raft storage on a persistent volume,
# static-key auto-unseal, TLS terminated by the OSC ingress, and declarative
# self-initialization (no root token or recovery keys are ever produced).
# Writes the server config through upstream's BAO_LOCAL_CONFIG, then hands over
# to upstream's docker-entrypoint.sh (which chowns its own dirs and drops root).
set -Eeuo pipefail

: "${BAO_STATIC_SEAL_KEY:?BAO_STATIC_SEAL_KEY (32-byte unseal key, hex or base64) is required}"
: "${BAO_ADMIN_PASSWORD:?BAO_ADMIN_PASSWORD (password for the initial admin user) is required}"

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

# The unseal key and the admin password are referenced via env://, env_var and
# are never written to the config file. The initialize section runs once, on
# the first start with empty storage; later starts ignore it.
export BAO_LOCAL_CONFIG="$(cat <<JSON
{
  "ui": true,
  "disable_mlock": true,
  "log_level": "${LOG_LEVEL}",
  "api_addr": "${API_ADDR}",
  "cluster_addr": "http://127.0.0.1:8201",
  "listener": [{ "tcp": { "address": "0.0.0.0:${PORT}", "tls_disable": true } }],
  "storage": { "raft": { "path": "${DATA_DIR}/raft", "node_id": "osc-node-1" } },
  "seal": { "static": { "current_key_id": "osc-1", "current_key": "env://BAO_STATIC_SEAL_KEY" } },
  "initialize": [
    {
      "osc-bootstrap": {
        "request": [
          { "enable-userpass": { "operation": "update", "path": "sys/auth/userpass",
              "data": { "type": "userpass", "config": { "listing_visibility": "unauth" } } } },
          { "superuser-policy": { "operation": "update", "path": "sys/policies/acl/superuser",
              "data": { "policy": "path \"*\" { capabilities = [\"create\",\"read\",\"update\",\"delete\",\"list\",\"sudo\"] }" } } },
          { "admin-user": { "operation": "update", "path": "auth/userpass/users/admin",
              "data": {
                "password": { "eval_type": "string", "eval_source": "env", "env_var": "BAO_ADMIN_PASSWORD", "require_present": true },
                "token_policies": ["superuser"]
              } } },
          { "enable-kv": { "operation": "update", "path": "sys/mounts/secret",
              "data": { "type": "kv", "options": { "version": "2" } } } }
        ]
      }
    }
  ]
}
JSON
)"

exec docker-entrypoint.sh "$@"
