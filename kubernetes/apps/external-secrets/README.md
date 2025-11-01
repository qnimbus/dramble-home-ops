# External Secrets with 1Password Connect

This directory contains the deployment configuration for External Secrets Operator with 1Password Connect integration.

## Overview

- **1Password Connect**: Provides a secure API to access 1Password secrets
- **External Secrets Operator**: Syncs secrets from 1Password to Kubernetes secrets

## Architecture

```
1Password Vault → 1Password Connect API → External Secrets Operator → Kubernetes Secrets
```

## Components

### 1. onepassword-connect/
- Deploys the 1Password Connect server
- Requires 1Password Connect credentials (`1password-credentials.json`)
- Exposes API on port 8080 within the cluster

### 2. external-secrets/
- Deploys the External Secrets Operator
- Includes SecretStore and ClusterSecretStore resources
- Provides example ExternalSecret configuration

## Setup Instructions

### Step 1: Get 1Password Connect Credentials

1. Sign in to your 1Password account (web interface)
2. Navigate to **Integrations** → **Secrets Automation**
3. Create a new **Connect Server**
4. Download the `1password-credentials.json` file
5. Generate a **Connect Token** (keep this secure)

### Step 2: Configure the Secret

Edit the file: `onepassword-connect/app/secret.sops.yaml`

Replace the placeholders with your actual credentials:
- Paste the contents of `1password-credentials.json`
- Add your Connect Token as `op-session`

### Step 3: Encrypt the Secret

Run the following command to encrypt the secret with SOPS:

```bash
sops -e -i kubernetes/apps/external-secrets/onepassword-connect/app/secret.sops.yaml
```

Verify the file is encrypted (you should see `sops:` metadata at the bottom).

### Step 4: Configure 1Password Vault

Edit `external-secrets/app/secretstore.yaml` and update the vault configuration:

```yaml
vaults:
  Kubernetes: 1  # Replace "Kubernetes" with your vault name
```

You can specify vaults by name or numeric ID.

### Step 5: Deploy to Cluster

If using Flux (already configured), simply commit and push:

```bash
git add kubernetes/apps/external-secrets/
git commit -m "Add external-secrets with 1password-connect"
git push
```

Flux will automatically deploy the resources.

Alternatively, apply manually:

```bash
kubectl apply -k kubernetes/apps/external-secrets/
```

### Step 6: Verify Deployment

Check that all pods are running:

```bash
kubectl get pods -n external-secrets
```

You should see:
- `onepassword-connect-*` (1Password Connect API)
- `external-secrets-*` (External Secrets Operator)
- `external-secrets-webhook-*` (Webhook for validation)
- `external-secrets-cert-controller-*` (Certificate management)

Check SecretStore status:

```bash
kubectl get secretstore,clustersecretstore -n external-secrets
```

Both should show `Valid: True` status.

## Usage

### Creating an ExternalSecret

1. Create a secret in your 1Password vault (e.g., vault "Kubernetes")
2. Note the item name (e.g., "my-app-credentials")
3. Add fields to the item (e.g., username, password, api-key)

4. Create an ExternalSecret resource:

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: my-app-secret
  namespace: default
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: onepassword
    kind: ClusterSecretStore
  target:
    name: my-app-credentials
    creationPolicy: Owner
  data:
    - secretKey: username
      remoteRef:
        key: my-app-credentials  # 1Password item name
        property: username        # Field in the item
    - secretKey: password
      remoteRef:
        key: my-app-credentials
        property: password
```

5. Apply the resource:

```bash
kubectl apply -f externalsecret.yaml
```

6. Verify the secret was created:

```bash
kubectl get secret my-app-credentials -n default
kubectl describe externalsecret my-app-secret -n default
```

### Using in HelmReleases

Reference the synced secret in your HelmRelease values:

```yaml
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: my-app
spec:
  values:
    env:
      - name: USERNAME
        valueFrom:
          secretKeyRef:
            name: my-app-credentials
            key: username
      - name: PASSWORD
        valueFrom:
          secretKeyRef:
            name: my-app-credentials
            key: password
```

## Troubleshooting

### 1Password Connect not starting

Check logs:
```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=onepassword-connect
```

Common issues:
- Invalid credentials in `1password-credentials.json`
- SOPS decryption failure (check age key is correct)

### ExternalSecret not syncing

Check ExternalSecret status:
```bash
kubectl describe externalsecret <name> -n <namespace>
```

Check operator logs:
```bash
kubectl logs -n external-secrets -l app.kubernetes.io/name=external-secrets
```

Common issues:
- Vault name mismatch
- Item not found in 1Password
- Invalid Connect Token
- SecretStore not ready

### SecretStore shows Invalid

Check SecretStore status:
```bash
kubectl describe secretstore onepassword -n external-secrets
```

Verify 1Password Connect is accessible:
```bash
kubectl port-forward -n external-secrets svc/onepassword-connect 8080:8080
curl http://localhost:8080/health
```

## Security Considerations

1. **Credentials**: The `1password-credentials.json` and Connect Token are highly sensitive
   - Always encrypt with SOPS before committing
   - Rotate tokens periodically
   
2. **Network Access**: 1Password Connect is only accessible within the cluster
   - No external exposure
   - Use NetworkPolicies to further restrict access if needed

3. **RBAC**: External Secrets Operator needs permissions to create secrets
   - Uses service accounts with minimal required permissions
   - Review RBAC if customizing

4. **Vault Isolation**: Consider using separate vaults for different environments
   - Development, staging, production
   - Configure separate SecretStores per environment

## Additional Resources

- [External Secrets Operator Docs](https://external-secrets.io/)
- [1Password Connect Docs](https://developer.1password.com/docs/connect/)
- [1Password Helm Chart](https://github.com/1Password/connect-helm-charts)
