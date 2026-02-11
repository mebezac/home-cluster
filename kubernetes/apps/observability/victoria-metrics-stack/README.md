# VictoriaMetrics Stack

This directory contains the configuration for deploying VictoriaMetrics as a replacement for the existing kube-prometheus-stack + Thanos observability stack.

## Components

| Component | Replaces | Purpose |
|-----------|-----------|---------|
| **VMSingle** | Prometheus + Thanos | Metrics storage with long-term retention |
| **VMAgent** | Prometheus scraping + Alloy | Metrics and logs collection |
| **VMAlert** | Prometheus alerting | Alerting rules evaluation |
| **VMAlertmanager** | AlertManager | Alert routing and notifications |

## Migration Path

The VictoriaMetrics Operator is configured to automatically convert Prometheus Operator CRDs (ServiceMonitors, PrometheusRules) to VictoriaMetrics equivalents. This allows the new stack to run in parallel with the existing stack during the migration phase.

## Key Features

- **30-day retention**: Built-in long-term storage, no Thanos needed
- **Prometheus compatible**: All existing ServiceMonitors and PrometheusRules work unchanged
- **Lower resource usage**: ~50% less RAM than Prometheus + Thanos
- **Simplified architecture**: Single binary instead of multiple components

## URLs

- **VMSingle**: https://vmsingle.laboratory.casa
- **VMAlertmanager**: https://alertmanager.laboratory.casa

## Next Steps

1. Deploy the stack: `kubectl apply -f /path/to/victoria-metrics-stack.yaml` (via ArgoCD)
2. Verify ServiceMonitors are being discovered
3. Update Grafana dashboards to use VictoriaMetrics datasource
4. Test alerting with VMAlertmanager
5. Once validated, decommission kube-prometheus-stack and Thanos

## Resource Requirements

- **Storage**: 20Gi (longhorn-single-replica)
- **RAM**: 256Mi-1Gi
- **CPU**: 100m minimum
