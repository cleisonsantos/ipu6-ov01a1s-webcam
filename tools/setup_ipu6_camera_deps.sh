#!/usr/bin/env bash
# Instala dependencias de build e os ipu6-camera-bins (libs proprietarias do ISP/AIQ).
# Uso:  sudo bash tools/setup_ipu6_camera_deps.sh
set -euo pipefail

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Erro: rode com sudo -> sudo bash $0"
    exit 1
fi

BINS="/home/css/dev/ipu6-camera-bins"
if [[ ! -d "${BINS}" ]]; then
    echo "Erro: ${BINS} nao encontrado."
    exit 1
fi

echo "== [1/3] Dependencias de build"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    build-essential cmake pkg-config autoconf automake libtool \
    libexpat1-dev libdrm-dev libva-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev \
    libgudev-1.0-dev libjson-c-dev uuid-dev libx11-dev

echo "== [2/3] ipu6-camera-bins -> /usr"
cd "${BINS}/lib"
for f in lib*.so.*; do
    ln -sf "$f" "${f%.*}"
done
cp -P lib* /usr/lib/
cp -r "${BINS}/include/." /usr/include/
mkdir -p /usr/lib/pkgconfig
cp -r "${BINS}/lib/pkgconfig/." /usr/lib/pkgconfig/
ldconfig

echo "== [3/3] Verificacao"
echo "-- libs:"
ls /usr/lib/libia_aiq-ipu6.so* 2>/dev/null | head -3
echo "-- headers:"
ls -d /usr/include/ia_imaging >/dev/null 2>&1 && echo "ia_imaging OK"
echo "-- pkgconfig:"
ls /usr/lib/pkgconfig/ | grep -iE 'ia_imaging|libgcss|libipu6' | head -5
echo
echo "Pronto. Agora avise o agente para compilar o HAL e o icamerasrc."
