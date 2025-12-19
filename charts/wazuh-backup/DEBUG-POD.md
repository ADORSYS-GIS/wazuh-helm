# Debug Pod Usage Guide

## Overview

The debug pod provides a convenient way to inspect both the source Wazuh PVC and the backup staging PVC simultaneously. This is useful for:
- Verifying backup contents
- Checking file permissions
- Debugging backup issues
- Reviewing cleanup operations

## Enabling the Debug Pod

1. **Edit values.yaml**:
   ```yaml
   debug:
     pod:
       enabled: true  # Change from false to true
       sourcePvc:
         name: "wazuh-wazuh-helm-manager-master-wazuh-wazuh-helm-manager-master-0"  # Update if needed
   ```

2. **Deploy/Upgrade the chart**:
   ```bash
   helm upgrade wazuh-backup charts/wazuh-backup -n wazuh
   ```

3. **Verify the pod is running**:
   ```bash
   kubectl get pods -n wazuh | grep debug
   ```

## Accessing the Debug Pod

### Shell into the pod:
```bash
kubectl exec -it -n wazuh wazuh-backup-debug -- sh
```

## Mounted Volumes

The debug pod has two mount points:

- **`/source`** - Source Wazuh Master PVC (read-only access)
  - Contains the live Wazuh data
  - Example: `/source/wazuh/var/ossec/etc/client.keys`

- **`/backup`** - Backup Staging PVC (read-write access)
  - Contains backup subdirectories
  - Example: `/backup/master-backup/`

## Useful Commands

### List backup contents:
```bash
# List all backups
ls -lah /backup/

# List specific backup
ls -lah /backup/master-backup/

# Tree view (if available)
tree /backup/master-backup/

# Check sizes
du -sh /backup/*
du -sh /backup/master-backup/*
```

### Compare source with backup:
```bash
# Compare file counts
find /source/wazuh/var/ossec/etc/ -type f | wc -l
find /backup/master-backup/var/ossec/etc/ -type f | wc -l

# Check specific files
ls -lh /source/var/ossec/etc/client.keys
ls -lh /backup/master-backup/var/ossec/etc/client.keys

# Diff files (if they exist in both places)
diff /source/var/ossec/etc/internal_options.conf \
     /backup/master-backup/var/ossec/etc/internal_options.conf
```

### Check recent backups:
```bash
# Find most recently modified files
find /backup/master-backup/ -type f -mmin -60 | sort

# Check backup timestamps
ls -lt /backup/master-backup/var/ossec/etc/
```

### Verify cleanup:
```bash
# Check if cleanup removed old backups
ls -lah /backup/

# Verify staging area is clean (should only see expected backups)
du -sh /backup/*/
```

### Search for specific files:
```bash
# Find all .pem files in backup
find /backup/master-backup/ -name "*.pem"

# Find all log files
find /backup/master-backup/ -name "*.log" | head -20

# Search for specific content
grep -r "some-pattern" /backup/master-backup/var/ossec/etc/
```

## Troubleshooting

### Pod won't start:
```bash
# Check pod status
kubectl describe pod wazuh-backup-debug -n wazuh

# Check PVC availability
kubectl get pvc -n wazuh
```

### PVC mount issues:
- Verify the `sourcePvc.name` in values.yaml matches your actual PVC name
- Check that both PVCs support `ReadWriteMany` or the pod is on the same node
- Ensure PVCs are not exclusively locked by other pods

### Permission denied errors:
```bash
# Check file permissions
ls -la /backup/master-backup/
ls -la /source/wazuh/var/ossec/etc/

# Check running user
id
whoami
```

## Disabling the Debug Pod

When you're done debugging:

1. **Set enabled to false**:
   ```yaml
   debug:
     pod:
       enabled: false
   ```

2. **Upgrade the chart**:
   ```bash
   helm upgrade wazuh-backup charts/wazuh-backup -n wazuh
   ```

3. **Verify deletion**:
   ```bash
   kubectl get pods -n wazuh | grep debug
   ```

## Security Considerations

⚠️ **Important Notes**:
- The debug pod has access to sensitive Wazuh data
- Only enable it when actively debugging
- Disable it in production environments when not in use
- The pod runs with minimal resources (100m CPU, 128Mi memory)

## Example Debugging Session

```bash
# 1. Shell into the pod
kubectl exec -it -n wazuh wazuh-backup-debug -- sh

# 2. Check backup contents
cd /backup/master-backup
ls -lah

# 3. Verify important files were backed up
test -f var/ossec/etc/client.keys && echo "✓ client.keys found" || echo "✗ client.keys missing"
test -f var/ossec/etc/sslmanager.cert && echo "✓ sslmanager.cert found" || echo "✗ missing"

# 4. Compare backup with source
ls -lh /source/var/ossec/etc/client.keys
ls -lh /backup/master-backup/var/ossec/etc/client.keys

# 5. Check backup sizes
du -sh /backup/master-backup/var/ossec/*

# 6. Exit when done
exit
```

## Quick Reference Card

```bash
# Access pod
kubectl exec -it -n wazuh wazuh-backup-debug -- sh

# List backups
ls -lah /backup/

# Check backup size
du -sh /backup/master-backup/

# Find files
find /backup/master-backup/ -name "client.keys"

# Compare directories
diff -r /source/var/ossec/etc/ /backup/master-backup/var/ossec/etc/ | head -20

# Exit
exit
```
