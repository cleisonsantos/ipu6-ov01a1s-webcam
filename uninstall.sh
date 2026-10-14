#!/usr/bin/env bash
#
# Desinstala o ipu6-ov01a1s-webcam (mantem HAL/bins/icamerasrc por padrao).
#
# Uso: sudo ./uninstall.sh
#
set -euo pipefail

KVER="$(uname -r)"
export PATH="/usr/sbin:/sbin:${PATH}"

[[ "$(id -u)" -eq 0 ]] || { echo "rode com sudo: sudo $0" >&2; exit 1; }

echo "==> Removendo DKMS do ipu-bridge"
dkms remove ipu-bridge-ovti01af/1.0 --all 2>/dev/null || true

echo "==> Restaurando ipu-bridge original (se houver backup)"
for f in /lib/modules/*/kernel/drivers/media/pci/intel/ipu-bridge.ko.xz.bak-*; do
    [[ -f "$f" ]] || continue
    target="${f%%.bak-*}"
    cp -a "$f" "$target"
    echo "   restaurado: $target"
done
depmod -a

echo "==> Removendo regras e launcher"
rm -f /etc/udev/rules.d/70-ipu6-psys.rules
udevadm control --reload 2>/dev/null || true
rm -f /etc/tmpfiles.d/camera.conf
rm -f /etc/modprobe.d/ipu6-webcam.conf
rm -f /etc/modules-load.d/ipu6-webcam.conf
rm -f /usr/local/bin/ipu6-webcam-start
rm -f /usr/lib/systemd/user/ipu6-webcam.service

echo
echo "Pronto. HAL, ipu6-camera-bins e icamerasrc foram mantidos."
echo "Para remove-los: rm -f /usr/lib/libcamhal.so* /usr/lib/libia_*.so* \\"
echo "  /usr/lib/pkgconfig/{libcamhal,ia_imaging,libgcss,libipu6}*.pc \\"
echo "  /usr/lib/gstreamer-1.0/libgsticamerasrc.so && sudo ldconfig"
