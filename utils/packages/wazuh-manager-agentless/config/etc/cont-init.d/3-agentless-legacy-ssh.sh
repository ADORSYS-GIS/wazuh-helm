#!/usr/bin/with-contenv bash
set -euo pipefail

AGENTLESS_DIR="/var/ossec/agentless"

legacyize_and_patch() {
  local src="$1"
  local dst="${src}_legacy"

  # Create legacy copy once (or refresh it if you prefer)
  if [[ -f "$src" && ! -f "$dst" ]]; then
    cp -a "$src" "$dst"
  fi

  # Only patch if the legacy file exists, contains the exact line, and isn't already patched
  if [[ -f "$dst" ]] \
     && grep -qE '^spawn ssh[[:space:]]+\$hostname[[:space:]]*$' "$dst" \
     && ! grep -q 'KexAlgorithms=' "$dst"
  then
    sed -i \
      's|^spawn ssh[[:space:]]\+\$hostname[[:space:]]*$|spawn ssh \\\n  -o KexAlgorithms=diffie-hellman-group1-sha1,diffie-hellman-group14-sha1 \\\n  -o HostKeyAlgorithms=ssh-rsa \\\n  -o PubkeyAcceptedAlgorithms=ssh-rsa \\\n  -o Ciphers=aes128-cbc \\\n  -o MACs=hmac-sha1 \\\n  \$hostname|g' \
      "$dst"
  fi
}

legacyize_and_patch "${AGENTLESS_DIR}/ssh_integrity_check_linux"
legacyize_and_patch "${AGENTLESS_DIR}/ssh_integrity_check_bsd"
legacyize_and_patch "${AGENTLESS_DIR}/ssh_pixconfig_diff"
legacyize_and_patch "${AGENTLESS_DIR}/ssh_generic_diff"
