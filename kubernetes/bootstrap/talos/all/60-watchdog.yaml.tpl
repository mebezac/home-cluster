{{- /*
Hardware watchdog (audit 2026-11-26 #99): wyse-5070-02 hung for 9.6 h and nothing reset it.
Machined pets the device; if Talos stops responding for `timeout`, the hardware resets the node.
Rendered only for nodes with `data.watchdog` (the device path) in topf.yaml. Checked 2026-11-27:
- elitebook (HP EliteBook 840 G3): iTCO_wdt -> /dev/watchdog0.
- wyse (Wyse 5070, Gemini Lake J4105): no device. Gemini Lake has no iTCO in i2c-i801/lpc_ich,
  no ACPI WDAT table, and the Talos kernel has no softdog (CONFIG_SOFT_WATCHDOG unset).
- talmac (Mac mini 2018): iTCO_wdt loads and the platform device exists, but the driver does
  not bind (no /dev/watchdog*), most likely the Apple firmware locks the TCO NO_REBOOT bit.
Applies without a reboot.
*/ -}}
{{- /* index: other nodes have no watchdog key, and topf fails on a missing key */ -}}
{{- if index .Node.Data "watchdog" }}
apiVersion: v1alpha1
kind: WatchdogTimerConfig
device: {{ .Node.Data.watchdog }}
timeout: 5m
{{- end }}
