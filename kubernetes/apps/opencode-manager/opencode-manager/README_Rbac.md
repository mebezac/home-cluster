# OpenCode Manager RBAC Configuration

This directory contains the RBAC resources required for OpenCode Manager to interact with the Kubernetes cluster.

## Resources Created

- **ServiceAccount**: `opencode-manager`
- **Role**: Full access to all namespaced resources (including secrets)
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

The RBAC is scoped to the namespace and fully permissive:
- All API groups and resources are allowed
- Includes secrets
- No cluster-wide permissions

## Security Implications

This Role grants full control over everything in the namespace, including secrets.
Do not place sensitive workloads or data in the `opencode-manager` namespace.
