#!/usr/bin/with-contenv bash
set -euo pipefail

AGENTLESS_DIR="/var/ossec/agentless"
BACKUP_DIR="${AGENTLESS_DIR}/backup-pre-ssh-compat"

mkdir -p "$BACKUP_DIR"

patch_spawn_ssh() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  # Backup once (keep original forever)
  if [[ ! -f "${BACKUP_DIR}/$(basename "$f")" ]]; then
    cp -a "$f" "${BACKUP_DIR}/"
  fi

  # Patch only if the line exists and isn't already patched
  if grep -qE '^[[:space:]]*spawn ssh[[:space:]]+\$hostname[[:space:]]*$' "$f" \
     && ! grep -q 'KexAlgorithms=' "$f"
  then
    # Preserve indentation via captured group \1
    sed -E -i \
      's|^([[:space:]]*)spawn ssh[[:space:]]+\$hostname[[:space:]]*$|\1spawn ssh \\\n\1  -o KexAlgorithms=diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \\\n\1  -o HostKeyAlgorithms=ssh-rsa \\\n\1  -o PubkeyAcceptedAlgorithms=ssh-rsa \\\n\1  -o Ciphers=aes128-cbc \\\n\1  -o MACs=hmac-sha1 \\\n\1  \$hostname|g' \
      "$f"
  fi
}

# Patch the 4 Wazuh agentless scripts in place
patch_spawn_ssh "${AGENTLESS_DIR}/ssh_integrity_check_linux"
patch_spawn_ssh "${AGENTLESS_DIR}/ssh_integrity_check_bsd"
patch_spawn_ssh "${AGENTLESS_DIR}/ssh_pixconfig_diff"
patch_spawn_ssh "${AGENTLESS_DIR}/ssh_generic_diff"
