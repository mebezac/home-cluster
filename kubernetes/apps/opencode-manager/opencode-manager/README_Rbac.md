# OpenCode Manager RBAC Configuration

This directory contains the RBAC resources required for OpenCode Manager to interact with the Kubernetes cluster.

## Resources Created

- **ServiceAccount**: `opencode-manager`
- **Role**: Permissions for pods, services, pod logs, and pod exec operations
- **RoleBinding**: Binds the ServiceAccount to the Role

## Getting the ServiceAccount Token

After applying these resources (via Argo CD sync), generate a long-lived token for OpenCode Manager to use:

```bash
kubectl create token opencode-manager -n opencode-manager --duration=8760h
```

Copy this token - you'll use it to configure OpenCode Manager in its Kubernetes settings.

## Configuring OpenCode Manager

1. Go to **Settings → Kubernetes**
2. Toggle "Enable Kubernetes" to ON
3. Set namespace to: `opencode-manager`
4. Use your kubeconfig or create a minimal kubeconfig file:

```yaml
apiVersion: v1
clusters:
- cluster:
    server: https://kubernetes.default.svc
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: opencode-manager
  name: opencode-manager
current-context: opencode-manager
kind: Config
preferences: {}
users:
- name: opencode-manager
  user:
    token: <YOUR_TOKEN_HERE>
```

## Security

The RBAC follows the principle of least privilege:
- Only pod and service operations are allowed
- Limited to the `opencode-manager` namespace
- No cluster-wide permissions
- No access to secrets, configmaps, or other sensitive resources
