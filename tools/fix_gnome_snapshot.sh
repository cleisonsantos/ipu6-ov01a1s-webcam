#!/usr/bin/env bash
# Corrige a camera virtual para funcionar no GNOME Snapshot E no Chrome:
#   1. v4l2loopback com exclusive_caps=1 (exigido pelo Chrome/WebRTC: ele
#      rejeita dispositivos que expoem captura E saida ao mesmo tempo)
#   2. regra udev forcando :video_capture: no loopback (assim o
#      PipeWire/portal/GNOME continuam vendo a camera)
#   3. esconde os nos raw do IPU6 (driver isys) da lista de cameras
#
# Obs.: o PipeWire tem um limite de 64 dispositivos no plugin SPA v4l2; como o
# IPU6 cria 64+ nos /dev/video, o /dev/video90 fica de fora. Rode tambem:
#   tools/build_patched_spa_v4l2.sh
#
# Uso: sudo bash tools/fix_gnome_snapshot.sh && sudo reboot
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Erro: rode com sudo -> sudo bash $0" >&2; exit 1; }

CONF=/etc/modprobe.d/ipu6-webcam.conf
LOOPBACK="${LOOPBACK:-/dev/video90}"
NODE_NAME="$(basename "${LOOPBACK}")"

echo "== v4l2loopback: exclusive_caps=1 (Chrome/WebRTC)"
if [[ -f "${CONF}" ]]; then
    if grep -q 'exclusive_caps=' "${CONF}"; then
        sed -i 's/exclusive_caps=[01]/exclusive_caps=1/' "${CONF}"
    else
        sed -i 's/^options v4l2loopback/options v4l2loopback exclusive_caps=1/' "${CONF}"
    fi
else
    echo 'options v4l2loopback devices=1 video_nr=90 card_label="IPU6 ISP Camera" exclusive_caps=1' > "${CONF}"
fi
cat "${CONF}"

echo
echo "== udev: forcar :video_capture: no ${LOOPBACK}"
cat > /etc/udev/rules.d/71-ipu6-loopback-caps.rules <<EOF
# Mantem o loopback visivel como camera para o PipeWire/portal mesmo com
# exclusive_caps=1 (exigido pelo Chrome/WebRTC).
SUBSYSTEM=="video4linux", KERNEL=="${NODE_NAME}", ENV{ID_V4L_CAPABILITIES}=":video_capture:video_output:"
EOF
udevadm control --reload
udevadm trigger --action=change --sysname-match="${NODE_NAME}" || true
cat /etc/udev/rules.d/71-ipu6-loopback-caps.rules

echo
echo "== WirePlumber: escondendo os nos raw do IPU6 (driver isys)"
mkdir -p /etc/wireplumber/wireplumber.conf.d
cat > /etc/wireplumber/wireplumber.conf.d/51-ipu6-hide-raw.conf <<'EOF'
# Esconde os nos raw do IPU6 (driver isys) da lista de cameras do PipeWire.
# O match e por device.name porque api.v4l2.cap.driver ainda nao existe no
# momento em que as regras do monitor v4l2 sao aplicadas.
monitor.v4l2.rules = [
  {
    matches = [
      { device.name = "~v4l2_device.pci-*" }
    ]
    actions = {
      update-props = {
        device.disabled = true
      }
    }
  }
]
EOF
cat /etc/wireplumber/wireplumber.conf.d/51-ipu6-hide-raw.conf

echo
echo "Pronto. Reinicie para aplicar:"
echo "  sudo reboot"
