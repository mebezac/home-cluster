# VictoriaLogs

This directory contains the configuration for deploying VictoriaLogs as a replacement for the existing Loki log aggregation stack.

## Migration Path

VictoriaLogs provides a Loki-compatible API endpoint at `/insert/loki/api/v1/push`, allowing existing log collectors to push logs with minimal changes.

## Key Features

- **Loki API compatible**: Drop-in replacement for Loki
- **High compression**: ~40% less storage than Loki
- **Fast queries**: 94% faster query latency
- **Resource efficient**: <50% CPU/RAM usage compared to Loki
- **Single binary**: No separate read/write/backend components

## Configuration

- **Retention**: 14 days (same as Loki)
- **Storage**: 30Gi on longhorn-single-replica (smaller than Loki's 50Gi due to better compression)
- **Persistent queue**: Enabled for reliability

## URLs

- **VictoriaLogs**: https://victorialogs.laboratory.casa

## Ingestion Endpoint

Logs should be sent to:
```
http://victoria-logs.observability.svc:9428/insert/loki/api/v1/push
```

This is the same endpoint format as Loki, so existing log collectors (Alloy, Promtail, etc.) can be updated by just changing the URL.

## Next Steps

1. Deploy VictoriaLogs: `kubectl apply -f /path/to/victoria-logs.yaml` (via ArgoCD)
2. Update log collectors to push to VictoriaLogs endpoint
3. Update Grafana to use VictoriaLogs datasource
4. Verify log ingestion and queries
5. Once validated, decommission Loki

## Resource Requirements

- **Storage**: 30Gi (longhorn-single-replica)
- **RAM**: 128Mi-512Mi
- **CPU**: 50m minimum
