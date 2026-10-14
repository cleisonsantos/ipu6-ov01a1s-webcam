#!/usr/bin/env bash
# Inicia a camera pelo ISP de hardware (ipu6-camera-hal + icamerasrc)
# e publica em /dev/video90 via v4l2loopback.
#
# Uso:  ipu6-webcam-start
#       OUTPUT=/dev/video90 WIDTH=1280 HEIGHT=720 ipu6-webcam-start
#       FLIP=no ipu6-webcam-start
set -euo pipefail

export PATH="/usr/sbin:/sbin:$PATH"

PLUGIN_DIR="${PLUGIN_DIR:-}"
CFG_DIR="${CFG_DIR:-}"
DEVICE="${DEVICE:-ov01a1s-uf}"
OUTPUT="${OUTPUT:-/dev/video90}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FLIP="${FLIP:-yes}"

# Config do HAL: usa a instalada no sistema, a menos que CFG_DIR seja passado.
if [[ -n "${CFG_DIR}" ]]; then
    export CAMERA_CFG_PATH="${CFG_DIR}"
fi

# Plugin: usa o instalado no sistema; senao, cai para a arvore de desenvolvimento.
if [[ -n "${PLUGIN_DIR}" ]]; then
    export GST_PLUGIN_PATH="${PLUGIN_DIR}"
elif ! gst-inspect-1.0 icamerasrc >/dev/null 2>&1; then
    for d in "$HOME/dev/icamerasrc-slim/src/.libs" \
             "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd)/icamerasrc-slim/src/.libs"; do
        if [[ -f "$d/libgsticamerasrc.so" ]]; then
            export GST_PLUGIN_PATH="$d"
            break
        fi
    done
fi

if ! gst-inspect-1.0 icamerasrc >/dev/null 2>&1; then
    echo "Erro: elemento icamerasrc nao encontrado." >&2
    echo "Rode ./install.sh ou compile ~/dev/icamerasrc-slim (branch icamerasrc_slim_api)." >&2
    exit 1
fi

pkill -f 'ipu6_ba10_to_loopback' 2>/dev/null || true
pkill -f 'gst-launch-1.0.*icamerasrc' 2>/dev/null || true

if [[ ! -e "${OUTPUT}" ]]; then
    echo "Criando v4l2loopback em ${OUTPUT}..."
    sudo modprobe v4l2loopback \
        devices=1 \
        video_nr="${OUTPUT#/dev/video}" \
        card_label="IPU6 ISP Camera" \
        exclusive_caps=1
fi

echo "Iniciando ISP: ${DEVICE} -> ${OUTPUT} (${WIDTH}x${HEIGHT})"
pipeline=(
    gst-launch-1.0 -e
    icamerasrc device-name="${DEVICE}" !
    "video/x-raw,format=YUY2,width=${WIDTH},height=${HEIGHT}" !
    videoconvert
)
if [[ "${FLIP}" == "yes" ]]; then
    pipeline+=(! videoflip method=rotate-180)
fi
pipeline+=(! v4l2sink device="${OUTPUT}")
exec "${pipeline[@]}"
