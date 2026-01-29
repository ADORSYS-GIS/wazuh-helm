#!/usr/bin/with-contenv bash
set -euo pipefail

AGENTLESS_DIR="/var/ossec/agentless"
BACKUP_DIR="${AGENTLESS_DIR}/backup-pre-ssh-compat"

mkdir -p "$BACKUP_DIR"

backup_once() {
  local f="$1"
  if [[ ! -f "${BACKUP_DIR}/$(basename "$f")" ]]; then
    cp -a "$f" "${BACKUP_DIR}/"
  fi
}

patch_spawn_ssh() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  backup_once "$f"

  if grep -qE '^[[:space:]]*spawn ssh[[:space:]]+\$hostname[[:space:]]*$' "$f" \
     && ! grep -q 'KexAlgorithms=' "$f"
  then
    sed -E -i \
      's|^([[:space:]]*)spawn ssh[[:space:]]+\$hostname[[:space:]]*$|\1spawn ssh \\\n\1  -o KexAlgorithms=diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \\\n\1  -o HostKeyAlgorithms=ssh-rsa \\\n\1  -o PubkeyAcceptedAlgorithms=ssh-rsa \\\n\1  -o Ciphers=aes128-cbc \\\n\1  -o MACs=hmac-sha1 \\\n\1  \$hostname|g' \
      "$f"
  fi
}

patch_stat_printf() {
  local f="$1"
  [[ -f "$f" ]] || return 0

  backup_once "$f"

  # Replace only if --printf exists
  if grep -q 'stat --printf' "$f"; then
    sed -i 's/stat --printf/stat --format/g' "$f"
  fi
}

# Patch all relevant agentless scripts in place
for script in \
  ssh_integrity_check_linux \
  ssh_integrity_check_bsd \
  ssh_pixconfig_diff \
  ssh_generic_diff
do
  file="${AGENTLESS_DIR}/${script}"

  patch_spawn_ssh "$file"
  patch_stat_printf "$file"
done
