---
description: Guidelines for translating apps from Flux to Argo CD
---

See `.agents/workflows/translate-flux-to-argo.md` in the project root for instructions on translating Flux HelmRelease resources to Argo CD Applications.

When translating apps:
1. Follow the directory structure conventions
2. Use ksops for secrets
3. Configure ingresses with laboratory.casa domain
4. Set up persistence using the documented patterns
5. Use the standard app-template chart version (4.6.2)
