# AWS Credentials Setup Guide

This chart uses the standard AWS credentials file approach for authentication, which is more secure and flexible than environment variables.

## 🚀 Quick Start

**Complete Installation Command:**

```bash
# 1. Create AWS credentials file
cat > credentials <<EOF
[default]
aws_access_key_id=YOUR_ACCESS_KEY_ID
aws_secret_access_key=YOUR_SECRET_ACCESS_KEY
region=eu-central-1
EOF

# 2. Create Kubernetes secret
kubectl create secret generic aws-creds \
  --namespace wazuh \
  --from-file=credentials=./credentials

# 3. Install the chart
helm install wazuh-backup ./charts/wazuh-backup \
  --namespace wazuh \
  --set aws.createSecret=false

# Default S3 bucket: wazuh-dev-backup (arn:aws:s3:::wazuh-dev-backup)
# Backups will be stored in: s3://wazuh-dev-backup/wazuh-backup/DD-MM-YY-wazuh-backup/
```

**Important:** Ensure your AWS credentials have permissions for:
- `s3:PutObject` on `arn:aws:s3:::wazuh-dev-backup/*`
- `s3:ListBucket` on `arn:aws:s3:::wazuh-dev-backup`

---

## Overview

The chart mounts `~/.aws/credentials` into the S3 upload container, allowing the AWS CLI to authenticate automatically without exposing credentials as environment variables.

---

## ✅ Recommended Approach: External Secret (Production)

### Step 1: Create a credentials file

Create a file named `credentials` with your AWS credentials:

```ini
[default]
aws_access_key_id=AKIAIOSFODNN7EXAMPLE
aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
region=eu-central-1
```

**For temporary credentials (AWS STS/AssumeRole):**
```ini
[default]
aws_access_key_id=ASIAIOSFODNN7EXAMPLE
aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
aws_session_token=FwoGZXIvYXdzEBYaD...
region=eu-central-1
```

### Step 2: Create the Kubernetes Secret

```bash
kubectl create secret generic aws-creds \
  --namespace wazuh \
  --from-file=credentials=./credentials
```

### Step 3: Install the chart with external secret

```bash
helm install wazuh-backup ./charts/wazuh-backup \
  --namespace wazuh \
  --set aws.createSecret=false \
  --set aws.secretName=aws-creds

# The default S3 bucket is: wazuh-dev-backup (arn:aws:s3:::wazuh-dev-backup)
# To use a different bucket:
# --set backup.s3.bucketName=your-bucket-name
```

**Why this is recommended:**
- ✅ Credentials never stored in Helm values
- ✅ Follows AWS best practices
- ✅ Easy to rotate credentials (update secret, restart pods)
- ✅ Supports IAM roles, STS tokens, and multiple profiles
- ✅ Can use external secret management (AWS Secrets Manager, Vault, etc.)

---

## Alternative: Chart-Managed Secret (Development/Testing)

For development or testing, you can let the chart create the secret from values.

### Step 1: Create a values file

Create `my-values.yaml`:

```yaml
aws:
  secretName: aws-creds
  createSecret: true
  credentialsFile: |
    [default]
    aws_access_key_id=AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    region=eu-central-1
```

### Step 2: Install the chart

```bash
helm install wazuh-backup ./charts/wazuh-backup \
  --namespace wazuh \
  --values my-values.yaml
```

⚠️ **Security Warning**: Never commit this values file to git! Add it to `.gitignore`.

---

## Advanced: Using AWS IAM Roles for Service Accounts (IRSA)

For production EKS deployments, use IRSA to avoid managing credentials entirely:

### Step 1: Create IAM role with trust policy

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/oidc.eks.REGION.amazonaws.com/id/OIDC_ID"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "oidc.eks.REGION.amazonaws.com/id/OIDC_ID:sub": "system:serviceaccount:wazuh:wazuh-backup-sa"
        }
      }
    }
  ]
}
```

### Step 2: Attach S3 policy to the role

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::wazuh-dev-backup/*",
        "arn:aws:s3:::wazuh-dev-backup"
      ]
    }
  ]
}
```

### Step 3: Annotate the service account

Update `values.yaml`:

```yaml
serviceaccounts:
  - name: '{{ include "common.names.fullname" $ }}-sa'
    enabled: true
    additionalAnnotations:
      eks.amazonaws.com/role-arn: arn:aws:iam::ACCOUNT_ID:role/wazuh-backup-role
```

### Step 4: No credentials needed!

With IRSA, the AWS CLI automatically uses the IAM role - no credentials file required. Set:

```yaml
aws:
  createSecret: false
```

And remove the aws-creds volume mount from the task (requires template modification).

---

## Credential File Format

### Standard credentials
```ini
[default]
aws_access_key_id=YOUR_ACCESS_KEY
aws_secret_access_key=YOUR_SECRET_KEY
region=eu-central-1
```

### With session token (STS)
```ini
[default]
aws_access_key_id=YOUR_ACCESS_KEY
aws_secret_access_key=YOUR_SECRET_KEY
aws_session_token=YOUR_SESSION_TOKEN
region=eu-central-1
```

### Multiple profiles
```ini
[default]
aws_access_key_id=DEFAULT_KEY
aws_secret_access_key=DEFAULT_SECRET
region=eu-central-1

[backup]
aws_access_key_id=BACKUP_KEY
aws_secret_access_key=BACKUP_SECRET
region=us-east-1
```

To use a specific profile, set `AWS_PROFILE=backup` in the task environment variables.

---

## Verifying Credentials

### Check if secret exists
```bash
kubectl get secret aws-creds -n wazuh
```

### View secret contents (base64 encoded)
```bash
kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.credentials}' | base64 -d
```

### Test from a pod
```bash
kubectl run aws-test --rm -it \
  --image=amazon/aws-cli:2.13.0 \
  --overrides='
{
  "spec": {
    "containers": [{
      "name": "aws-test",
      "image": "amazon/aws-cli:2.13.0",
      "command": ["/bin/bash"],
      "volumeMounts": [{
        "name": "aws-creds",
        "mountPath": "/root/.aws",
        "readOnly": true
      }]
    }],
    "volumes": [{
      "name": "aws-creds",
      "secret": {
        "secretName": "aws-creds"
      }
    }]
  }
}' \
  --namespace wazuh \
  -- /bin/bash

# Inside the pod:
aws s3 ls
cat ~/.aws/credentials
```

---

## Rotating Credentials

### Update the secret
```bash
kubectl create secret generic aws-creds \
  --namespace wazuh \
  --from-file=credentials=./new-credentials \
  --dry-run=client -o yaml | kubectl apply -f -
```

### Restart affected pods
Tekton tasks will automatically use the new credentials on the next run. No restart needed!

---

## Troubleshooting

### Error: "Unable to locate credentials"

**Cause**: Secret not mounted or doesn't exist

**Solution**:
```bash
# Verify secret exists
kubectl get secret aws-creds -n wazuh

# Verify secret has credentials key
kubectl get secret aws-creds -n wazuh -o jsonpath='{.data.credentials}' | base64 -d
```

### Error: "The security token included in the request is expired"

**Cause**: Using temporary credentials (STS) that expired

**Solution**: Regenerate STS token and update the secret:
```bash
# Get new STS credentials
aws sts get-session-token --duration-seconds 3600

# Update credentials file with new token
# Recreate the secret (see "Rotating Credentials" above)
```

### Error: "Access Denied" when uploading to S3

**Cause**: IAM permissions insufficient

**Solution**: Verify IAM policy allows:
- `s3:PutObject` on bucket
- `s3:ListBucket` on bucket

```bash
# Test with your configured bucket
aws s3 cp test.txt s3://wazuh-dev-backup/test.txt --profile default
```

---

## Configuration Reference

### values.yaml

```yaml
aws:
  # Name of the Kubernetes secret containing credentials file
  secretName: aws-creds

  # If true, chart creates the secret from credentialsFile
  # If false, you must create the secret externally (recommended)
  createSecret: false

  # Credentials file content (used only if createSecret=true)
  credentialsFile: |
    [default]
    aws_access_key_id=
    aws_secret_access_key=
    region=eu-central-1
```

### How it works

1. **Secret Creation**: Either chart-managed or external
2. **Volume Mount**: Secret mounted at `/root/.aws/` in upload container
3. **File Location**: Credentials available at `/root/.aws/credentials`
4. **AWS CLI**: Automatically reads credentials from `~/.aws/credentials`
5. **Permissions**: File mounted with mode `0400` (read-only for owner)

---

## Security Best Practices

✅ **DO**:
- Use external secrets (not chart-managed) in production
- Use IAM roles (IRSA) when possible on EKS
- Rotate credentials regularly
- Use temporary credentials (STS) when possible
- Set minimal IAM permissions (least privilege)
- Add credentials file to `.gitignore`

❌ **DON'T**:
- Commit credentials to version control
- Use root AWS account credentials
- Grant overly broad IAM permissions
- Share credentials across environments (dev/prod)
- Store credentials in Helm values for production

---

## Migration from Old Format

If migrating from the old environment variable approach:

### Old values.yaml
```yaml
aws:
  region: eu-central-1
  secretName: aws-creds
  accessKeyId: "AKIAIOSFODNN7EXAMPLE"
  secretAccessKey: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
  sessionToken: ""
```

### New values.yaml
```yaml
aws:
  secretName: aws-creds
  createSecret: true
  credentialsFile: |
    [default]
    aws_access_key_id=AKIAIOSFODNN7EXAMPLE
    aws_secret_access_key=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
    region=eu-central-1
```

### Or (recommended)
```yaml
aws:
  secretName: aws-creds
  createSecret: false  # Create secret externally
```

Then create the secret:
```bash
kubectl create secret generic aws-creds \
  --namespace wazuh \
  --from-file=credentials=./credentials
```
