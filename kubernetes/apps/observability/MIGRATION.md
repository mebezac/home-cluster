# Observability Migration to VictoriaMetrics

## Overview

This migration replaces the existing Grafana LGTM stack (Prometheus + Thanos + Loki + Alloy) with the VictoriaMetrics stack (VMSingle + VMAgent + VMAlert + VMAlertmanager + VictoriaLogs).

## Migration Goals

- **Resource efficiency**: Reduce RAM usage by 50% and storage by 45%
- **Simplification**: Eliminate Thanos complexity (single binary approach)
- **Performance**: Faster queries with better compression
- **Maintainability**: Unified stack from a single project

## Component Mapping

| Current Component | New Component | ArgoCD App |
|-----------------|---------------|-------------|
| kube-prometheus-stack | victoria-metrics-stack | `victoria-metrics-stack` |
| Prometheus | VMSingle | Included in stack |
| Thanos (all components) | Built-in VMSingle retention | Removed |
| AlertManager | VMAlertmanager | Included in stack |
| loki | victoria-logs | `victoria-logs` |
| alloy | victoria-logs-collector (vlagent) | `victoria-logs-collector` |

## Resource Comparison

| Metric | Before | After | Savings |
|--------|--------|-------|---------|
| **Total RAM** | ~2-3 GB | ~800MB-1.2GB | **50-60%** |
| **Total Storage** | ~91 Gi | ~50 Gi | **45%** |
| **Pod Count** | ~15 pods | ~8 pods | **47%** |

## Deployment Order

### Phase 1: Deploy New Stack (Parallel)

1. **Deploy victoria-metrics-stack**
   ```bash
   git add kubernetes/argo/apps/observability/victoria-metrics-stack.yaml kubernetes/apps/observability/victoria-metrics-stack
   git commit -m "feat: add victoria metrics stack for observability migration"
   git push
   ```
   - Argo CD will reconcile automatically
   - VMSingle will start collecting metrics
   - VMOperator will convert existing ServiceMonitors and PrometheusRules
   - VMAlert will evaluate alerting rules
   - VMAlertmanager will handle notifications

2. **Deploy victoria-logs**
   ```bash
   git add kubernetes/argo/apps/observability/victoria-logs.yaml kubernetes/apps/observability/victoria-logs
   git commit -m "feat: add victoria logs for observability migration"
   git push
   ```
   - Argo CD will reconcile automatically
   - VictoriaLogs will be ready to receive logs

3. **Verify Grafana datasources**
   - VictoriaMetrics datasource added: `http://vmsingle-victoria-metrics-stack.observability.svc:8428`
   - VictoriaLogs datasource added: `http://victoria-logs-victoria-logs-single-server.observability.svc.cluster.local:9428`
   - VMAlertmanager datasource added: `http://vmalertmanager-victoria-metrics-stack.observability.svc:9093`

### Phase 2: Validation

- [ ] VMAgent is scraping all ServiceMonitors
- [ ] Metrics appear in VMSingle
- [ ] All existing dashboards work with VictoriaMetrics datasource
- [ ] VMAlert is evaluating all rules
- [ ] Pushover notifications work via VMAlertmanager
- [ ] Logs can be queried in VictoriaLogs

### Phase 3: Log Collection Update

Update Alloy config to push logs to VictoriaLogs:

```alloy
loki.write "default" {
  endpoint {
    url = "http://victoria-logs-victoria-logs-single-server.observability.svc.cluster.local:9428/insert/loki/api/v1/push"
  }
}
```

Or replace Alloy with `victoria-logs-collector` (`vlagent`) for native VictoriaLogs collection (recommended).

### Phase 4: Cutover

1. Update Grafana dashboards to use VictoriaMetrics datasource
2. Make VictoriaMetrics the default datasource (already configured)
3. Monitor both stacks in parallel for 1 week

### Phase 5: Decommission Old Stack

Once validation is complete:

1. **Remove Thanos** (no longer needed)
   ```bash
   git rm kubernetes/argo/apps/observability/thanos.yaml
   git commit -m "chore: remove thanos after victoria migration"
   git push
   ```

2. **Remove kube-prometheus-stack** (replaced by VM stack)
   ```bash
   git rm kubernetes/argo/apps/observability/kube-prometheus-stack.yaml
   git commit -m "chore: remove kube-prometheus-stack after victoria migration"
   git push
   ```

3. **Remove prometheus-operator-crds** (VM operator handles them)
   ```bash
   git rm kubernetes/argo/apps/observability/prometheus-operator-crds.yaml
   git commit -m "chore: remove prometheus operator crds after victoria migration"
   git push
   ```

4. **Remove Loki** (replaced by VictoriaLogs)
   ```bash
   git rm kubernetes/argo/apps/observability/loki.yaml
   git commit -m "chore: remove loki after victoria logs migration"
   git push
   ```

5. **Remove Alloy** (replaced by victoria-logs-collector)
   ```bash
   git rm kubernetes/argo/apps/observability/alloy.yaml
     git commit -m "chore: remove alloy after victoria logs collector migration"
   git push
   ```

## Important Notes

### AlertManager Configuration Migration

The existing AlertManager configuration can be reused by VMAlertmanager. The main differences in this repo are:

- We provide raw `alertmanager.yaml` via `configSecret` (`vmalertmanager-config`)
- `matchers` syntax is supported and should be kept for current Alertmanager versions
- Pushover integration is unchanged (using `user_key_file` / `token_file` from mounted secret)
- VMAlert notifier endpoints are chart-managed via `alertmanager.enabled: true`

Example matcher syntax (valid for VMAlertmanager config):
```yaml
# Alertmanager route matcher
matchers:
  - alertname =~ "InfoInhibitor|Watchdog"
```

### PrometheusRule Compatibility

All existing PrometheusRule CRDs work with VMAlert automatically. The VM operator converts them at runtime.

### Grafana Dashboards

Most dashboards work unchanged because:
- VictoriaMetrics supports PromQL (MetricsQL is 99% compatible)
- Datasource type is still `prometheus`
- Query syntax is the same

Some dashboards may need minor adjustments for:
- Recording rules that use special PromQL features
- Alertmanager panels (need to update URL)

### Log Collection

During migration, Alloy can continue sending logs to both Loki and VictoriaLogs:

```alloy
loki.write "loki" {
  endpoint {
    url = "http://loki-headless.observability.svc.cluster.local:3100/loki/api/v1/push"
  }
}

loki.write "victorialogs" {
  endpoint {
     url = "http://victoria-logs-victoria-logs-single-server.observability.svc.cluster.local:9428/insert/loki/api/v1/push"
  }
}

loki.process "pod_logs" {
  forward_to = [loki.write.loki.receiver, loki.write.victorialogs.receiver]
  # ...
}
```

## Rollback Plan

If issues arise, you can:
1. Update Grafana to use old datasources (Prometheus, Loki)
2. Disable VMAlertmanager routing
3. Scale down VictoriaMetrics components
4. All old PVCs remain for recovery

## References

- [VictoriaMetrics Documentation](https://docs.victoriametrics.com/)
- [VictoriaLogs vs Loki Benchmark](https://www.tinker.expert/blog/victorialogs-vs-loki)
- [VM Operator Migration Guide](https://docs.victoriametrics.com/operator/migration/)
- [VictoriaLogs Data Ingestion](https://docs.victoriametrics.com/victorialogs/data-ingestion/)
