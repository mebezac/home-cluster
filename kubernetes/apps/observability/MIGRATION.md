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
| alloy | VMAgent (unified metrics + logs) | Included in stack |

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
   kubectl apply -f kubernetes/argo/apps/observability/victoria-metrics-stack.yaml
   ```
   - VMSingle will start collecting metrics
   - VMOperator will convert existing ServiceMonitors and PrometheusRules
   - VMAlert will evaluate alerting rules
   - VMAlertmanager will handle notifications

2. **Deploy victoria-logs**
   ```bash
   kubectl apply -f kubernetes/argo/apps/observability/victoria-logs.yaml
   ```
   - VictoriaLogs will be ready to receive logs

3. **Verify Grafana datasources**
   - VictoriaMetrics datasource added: `http://vmsingle-victoria-metrics-stack.observability.svc:8429`
   - VictoriaLogs datasource added: `http://victoria-logs.observability.svc:9428`
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
    url = "http://victoria-logs.observability.svc:9428/insert/loki/api/v1/push"
  }
}
```

Or migrate to VMAgent for unified collection (recommended).

### Phase 4: Cutover

1. Update Grafana dashboards to use VictoriaMetrics datasource
2. Make VictoriaMetrics the default datasource (already configured)
3. Monitor both stacks in parallel for 1 week

### Phase 5: Decommission Old Stack

Once validation is complete:

1. **Remove Thanos** (no longer needed)
   ```bash
   kubectl delete -f kubernetes/argo/apps/observability/thanos.yaml
   ```

2. **Remove kube-prometheus-stack** (replaced by VM stack)
   ```bash
   kubectl delete -f kubernetes/argo/apps/observability/kube-prometheus-stack.yaml
   ```

3. **Remove prometheus-operator-crds** (VM operator handles them)
   ```bash
   kubectl delete -f kubernetes/argo/apps/observability/prometheus-operator-crds.yaml
   ```

4. **Remove Loki** (replaced by VictoriaLogs)
   ```bash
   kubectl delete -f kubernetes/argo/apps/observability/loki.yaml
   ```

5. **Remove Alloy** (replaced by VMAgent)
   ```bash
   kubectl delete -f kubernetes/argo/apps/observability/alloy.yaml
   ```

## Important Notes

### AlertManager Configuration Migration

The existing AlertManager configuration needs to be migrated to VMAlertmanager format. The main differences:

- AlertManager uses `matchers`, VMAlertmanager uses `match`
- Both support the same Pushover integration
- Config file format is nearly identical

Example migration:
```yaml
# AlertManager (old)
matchers:
  - name: alertname
    value: InfoInhibitor|Watchdog
    matchType: =~

# VMAlertmanager (new)
match:
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
    url = "http://victoria-logs.observability.svc:9428/insert/loki/api/v1/push"
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
