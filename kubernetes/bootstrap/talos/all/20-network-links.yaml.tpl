apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.macAddr }}", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
mtu: 1500
addresses:
  - address: "{{ .Node.IP }}/24"
routes:
  - gateway: "{{ .Data.gateway }}"
{{- if .Node.Data.vip }}
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
name: "{{ .Data.vip }}"
link: ethSel0
{{- end }}
