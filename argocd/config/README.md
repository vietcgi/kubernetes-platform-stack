# ArgoCD GitHub SSO Configuration

This directory contains the configuration files for setting up GitHub OAuth SSO with ArgoCD.

## Prerequisites

1. Sealed Secrets controller installed in your cluster
2. `kubeseal` CLI tool installed locally
3. GitHub account with access to create OAuth Apps

## Setup Instructions

### Step 1: Create GitHub OAuth Application

1. Go to your GitHub organization settings: `https://github.com/organizations/YOUR_ORG/settings/applications`
   - Or for personal accounts: `https://github.com/settings/developers`
2. Click **"OAuth Apps"** → **"New OAuth App"**
3. Fill in the application details:
   - **Application name**: `ArgoCD`
   - **Homepage URL**: `https://argocd.example.com` (replace with your actual ArgoCD URL)
   - **Authorization callback URL**: `https://argocd.example.com/api/dex/callback`
4. Click **"Register application"**
5. Copy the **Client ID**
6. Click **"Generate a new client secret"** and copy the **Client Secret**

### Step 2: Create the OAuth Secret

Create a SealedSecret with your GitHub OAuth credentials:

```bash
# Create the secret (replace with your actual values)
kubectl create secret generic argocd-secret \
  --from-literal=dex.github.clientID=YOUR_CLIENT_ID \
  --from-literal=dex.github.clientSecret=YOUR_CLIENT_SECRET \
  --namespace=argocd \
  --dry-run=client -o yaml | \
kubeseal -o yaml > argocd-github-oauth-sealed-secret.yaml

# Add the sealed secret to kustomization.yaml resources
# Then commit and push
```

### Step 3: Update Configuration Files

Edit the following files to match your organization:

#### argocd-cm.yaml
- Update `url:` with your actual ArgoCD URL
- Update `orgs.name:` with your GitHub organization name

#### argocd-rbac-cm.yaml
- Update `your-org-name` with your GitHub organization name
- Update team names (`admins`, `developers`) to match your GitHub teams
- Customize RBAC policies as needed

### Step 4: Apply Configuration

```bash
# Apply the configuration via ArgoCD
cd argocd/config
kubectl apply -k .

# Or sync via ArgoCD CLI
argocd app sync argocd-config
```

### Step 5: Restart ArgoCD Server

```bash
# Restart the ArgoCD server to pick up the new configuration
kubectl rollout restart deployment argocd-server -n argocd

# Wait for rollout to complete
kubectl rollout status deployment argocd-server -n argocd
```

### Step 6: Test SSO Login

1. Navigate to your ArgoCD URL
2. Click **"LOG IN VIA GITHUB"**
3. Authorize the application
4. You should be logged in with your GitHub account

## RBAC Configuration

The default RBAC configuration includes three roles:

### Admin Role
- Full access to all resources
- Granted to: `your-org-name:admins` team

### Developer Role
- Manage applications and repositories
- Granted to: `your-org-name:developers` team

### Readonly Role (Default)
- View-only access
- Granted to: All organization members

## Troubleshooting

### SSO Button Not Appearing
- Check ArgoCD server logs: `kubectl logs -n argocd deployment/argocd-server`
- Verify the `dex.config` in argocd-cm ConfigMap

### Authentication Fails
- Verify the callback URL matches exactly: `https://YOUR_URL/api/dex/callback`
- Check that the Client ID and Secret are correct
- Check Dex logs: `kubectl logs -n argocd deployment/argocd-dex-server`

### RBAC Issues
- Check the RBAC policy in argocd-rbac-cm ConfigMap
- Verify your GitHub teams and organization name are correct
- Check ArgoCD server logs for RBAC evaluation messages

## Security Notes

- Never commit the actual GitHub OAuth secret to Git
- Use Sealed Secrets or another secret management solution
- Regularly rotate OAuth credentials
- Review and audit RBAC policies periodically
- Consider using GitHub team synchronization for dynamic access control

## References

- [ArgoCD SSO Configuration](https://argo-cd.readthedocs.io/en/stable/operator-manual/user-management/)
- [ArgoCD RBAC](https://argo-cd.readthedocs.io/en/stable/operator-manual/rbac/)
- [Dex GitHub Connector](https://dexidp.io/docs/connectors/github/)
