#!/bin/bash
# Wazuh SCA Policy Sync Script
# Automatically copies SCA policies from shared folder to ruleset
# This ensures custom SCA policies from the manager are loaded by the agent

SHARED_DIR="/Library/Ossec/etc/shared"
RULESET_DIR="/Library/Ossec/ruleset/sca"

# Exit if directories don't exist
[ -d "$SHARED_DIR" ] || exit 0
[ -d "$RULESET_DIR" ] || exit 0

# Sync all .yml files from shared to ruleset
for sca_file in "$SHARED_DIR"/*.yml; do
    [ -f "$sca_file" ] || continue

    filename=$(basename "$sca_file")

    # Skip if file exists and is identical
    if [ -f "$RULESET_DIR/$filename" ]; then
        cmp -s "$sca_file" "$RULESET_DIR/$filename" && continue
    fi

    # Copy the policy
    cp "$sca_file" "$RULESET_DIR/" 2>/dev/null
done

exit 0
