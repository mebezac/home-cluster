# NOTE: this is the ONE deliberate deprecated v1alpha1 block. Talos 1.14 has no multi-doc
# equivalent for .machine.kubelet.extraMounts ("upgrading-talos" guide), and KubeletConfig is
# mutually exclusive with .machine.kubelet - so the generated KubeletConfig is deleted below and
# its fields (image, seccomp default) are carried here instead. Kubelet only sees /var/lib/kubelet
# and /var/mnt (ro) otherwise; Longhorn needs /var/lib/longhorn bind-mounted rshared into the
# kubelet. Revisit when Talos adds a multi-doc extraMounts.
machine:
  kubelet:
    image: ghcr.io/siderolabs/kubelet:{{ .KubernetesVersion }}
    defaultRuntimeSeccompProfileEnabled: true
    extraConfig:
      # Age-based image GC. Without this, kubelet only reclaims images under
      # disk pressure (imageGCHighThresholdPercent 85 / low 80), so stale
      # versions accumulate forever. talmac-01 reached 147.7GB of images on a
      # 249GB root disk (82% full) with SEVEN music-assistant versions, six
      # Home Assistant, five ESPHome and four Immich still cached - and GC had
      # never fired because 82% sits between the low and high thresholds.
      #
      # 168h = 1 week. Safe to be aggressive here specifically BECAUSE Spegel
      # runs: every node mirrors images to its peers, so an aged-out image is
      # re-pulled from another node over the LAN rather than from the internet.
      # Must stay above imageMinimumGCAge (2m0s).
      imageMaximumGCAge: 168h
    extraMounts:
      - destination: /var/lib/longhorn
        type: bind
        source: /var/lib/longhorn
        options: [bind, rshared, rw]
---
apiVersion: v1alpha1
kind: KubeletConfig
$patch: delete
---
apiVersion: v1alpha1
kind: KubeNodeConfig
nodeIP:
  validSubnets:
    - 10.25.30.0/24
