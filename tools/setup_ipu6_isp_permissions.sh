#!/usr/bin/env bash
# Da acesso ao /dev/ipu-psys0 para o grupo video (ISP de hardware) e cria /run/camera.
# Uso:  sudo bash tools/setup_ipu6_isp_permissions.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Erro: rode com sudo -> sudo bash $0"
    exit 1
fi

echo "== Regra udev para /dev/ipu-psys0"
cat > /etc/udev/rules.d/70-ipu6-psys.rules <<'EOF'
SUBSYSTEM=="intel-ipu6-psys", KERNEL=="ipu-psys0", GROUP="video", MODE="0660"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=intel-ipu6-psys || true
sleep 1

echo "== /run/camera (AIQD/logs do HAL)"
mkdir -p /run/camera
chmod 0777 /run/camera
cat > /etc/tmpfiles.d/camera.conf <<'EOF'
d /run/camera 0777 root root -
EOF

echo "== Resultado:"
ls -l /dev/ipu-psys0
ls -ld /run/camera
echo
echo "Pronto. Agora teste (sem sudo):"
echo "  GST_PLUGIN_PATH=~/dev/icamerasrc-slim/src/.libs CAMERA_CFG_PATH=~/dev/webcam/ipu6-hal-config/ \\"
echo "    gst-launch-1.0 icamerasrc device-name=ov01a1s-uf ! video/x-raw,format=YUY2,width=1280,height=720 ! videoconvert ! v4l2sink device=/dev/video90"
