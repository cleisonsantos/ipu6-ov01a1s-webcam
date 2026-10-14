#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BRIDGE="${ROOT_DIR}/build/bin/ipu6_ba10_to_loopback"

INPUT="${INPUT:-/dev/video40}"
OUTPUT="${OUTPUT:-/dev/video90}"
SUBDEV="${SUBDEV:-/dev/v4l-subdev8}"
MEDIA="${MEDIA:-/dev/media0}"
WIDTH="${WIDTH:-1288}"
HEIGHT="${HEIGHT:-800}"
FPS="${FPS:-30}"
TARGET_LUMA="${TARGET_LUMA:-95}"
CONTRAST="${CONTRAST:-950}"
BRIGHTNESS="${BRIGHTNESS:--12}"
ROTATE="${ROTATE:-yes}"
COLOR="${COLOR:-no}"
FAST="${FAST:-yes}"
IR_SUBTRACT="${IR_SUBTRACT:-128}"
SATURATION="${SATURATION:-650}"
U_GAIN="${U_GAIN:-700}"
V_GAIN="${V_GAIN:-1200}"
U_OFFSET="${U_OFFSET:-0}"
V_OFFSET="${V_OFFSET:-0}"
HUE_DEG="${HUE_DEG:-0}"
VBLANK="${VBLANK:-96}"
EXPOSURE="${EXPOSURE:-888}"
ANALOGUE_GAIN="${ANALOGUE_GAIN:-65535}"
DIGITAL_GAIN="${DIGITAL_GAIN:-2048}"

if [[ "${EUID}" -ne 0 ]]; then
    sudo -v
fi

ensure_devnode_from_class() {
    local class_dir="$1"
    local dev_path="$2"
    local devno major minor

    [[ -e "${class_dir}/dev" ]] || return 1
    [[ -e "${dev_path}" ]] && return 0

    devno="$(cat "${class_dir}/dev")"
    major="${devno%%:*}"
    minor="${devno##*:}"
    sudo mknod "${dev_path}" c "${major}" "${minor}"
    sudo chgrp video "${dev_path}" 2>/dev/null || true
    sudo chmod 660 "${dev_path}" 2>/dev/null || true
}

ensure_video_devnode() {
    local name="$1"

    ensure_devnode_from_class "/sys/class/video4linux/${name}" "/dev/${name}" || true
}

ensure_media_devnode() {
    local name="$1"

    ensure_devnode_from_class "/sys/class/media/${name}" "/dev/${name}" || \
        ensure_devnode_from_class "/sys/bus/media/devices/${name}" "/dev/${name}" || true
}

ensure_known_devnodes() {
    ensure_media_devnode "${MEDIA##*/}"
    ensure_video_devnode "${INPUT##*/}"
    ensure_video_devnode "${OUTPUT##*/}"

    for node in /sys/class/video4linux/v4l-subdev*; do
        [[ -e "${node}" ]] || continue
        ensure_video_devnode "${node##*/}"
    done
}

bind_ov01a1s_if_needed() {
    local sensor="/sys/bus/i2c/devices/i2c-OVTI01AF:00"
    local driver="/sys/bus/i2c/drivers/ov01a1s"

    [[ -e "${sensor}" && -e "${driver}" ]] || return 0
    [[ -L "${sensor}/driver" ]] && return 0

    echo "Aviso: OVTI01AF existe, mas nao esta ligado ao driver ov01a1s; tentando bind manual." >&2
    if ! echo i2c-OVTI01AF:00 | sudo tee "${driver}/bind" >/dev/null; then
        echo "Erro: bind manual do OVTI01AF no ov01a1s falhou." >&2
        echo "Rode para ver o motivo:" >&2
        echo "  sudo dmesg | grep -Ei 'ov01a1s|OVTI01AF|ipu6|failed|error|deferred' | tail -120" >&2
        exit 1
    fi
    sleep 0.5

    if [[ ! -L "${sensor}/driver" ]]; then
        echo "Erro: OVTI01AF ainda nao ficou ligado ao driver ov01a1s apos o bind." >&2
        echo "Rode para ver o motivo:" >&2
        echo "  sudo dmesg | grep -Ei 'ov01a1s|OVTI01AF|ipu6|failed|error|deferred' | tail -120" >&2
        exit 1
    fi
}

detect_sensor_subdev() {
    local node

    for node in /sys/class/video4linux/v4l-subdev*; do
        [[ -e "${node}/name" ]] || continue
        if grep -q '^ov01a1s ' "${node}/name"; then
            SUBDEV="/dev/${node##*/}"
            return 0
        fi
    done
}

if [[ ! -x "${BRIDGE}" ]]; then
    make -C "${ROOT_DIR}" build/bin/ipu6_ba10_to_loopback
fi

pkill -f "${BRIDGE}" 2>/dev/null || true
bind_ov01a1s_if_needed
ensure_known_devnodes
detect_sensor_subdev || true

if [[ ! -e "${OUTPUT}" ]]; then
    sudo modprobe -r v4l2loopback 2>/dev/null || true
    sudo modprobe v4l2loopback \
        devices=1 \
        video_nr="${OUTPUT#/dev/video}" \
        card_label="IPU6 Virtual Camera" \
        exclusive_caps=1
    ensure_video_devnode "${OUTPUT##*/}"
fi

if [[ ! -e "${OUTPUT}" ]]; then
    echo "Erro: ${OUTPUT} nao foi criado pelo v4l2loopback." >&2
    echo "Verifique se o modulo v4l2loopback esta instalado e se nao ha outro app usando o loopback." >&2
    echo "Diagnostico rapido:" >&2
    echo "  lsmod | grep v4l2loopback" >&2
    echo "  v4l2-ctl --list-devices | grep -A3 -i loopback" >&2
    exit 1
fi

if [[ -e "${SUBDEV}" ]]; then
    sudo v4l2-ctl -d "${SUBDEV}" --set-ctrl=test_pattern=0 >/dev/null 2>&1 || true
    sudo v4l2-ctl -d "${SUBDEV}" --set-ctrl=vertical_blanking="${VBLANK}" >/dev/null 2>&1 || true
    sudo v4l2-ctl -d "${SUBDEV}" --set-ctrl=exposure="${EXPOSURE}" >/dev/null 2>&1 || true
    sudo v4l2-ctl -d "${SUBDEV}" --set-ctrl=analogue_gain="${ANALOGUE_GAIN}" >/dev/null 2>&1 || true
    sudo v4l2-ctl -d "${SUBDEV}" --set-ctrl=digital_gain="${DIGITAL_GAIN}" >/dev/null 2>&1 || true
else
    echo "Aviso: subdev do sensor ov01a1s nao encontrado; controles de exposicao nao serao aplicados." >&2
fi

ensure_known_devnodes

if command -v media-ctl >/dev/null 2>&1 && [[ -e "${MEDIA}" ]]; then
    media-ctl -d "${MEDIA}" \
        -l "'ov01a1s 4-0036':0 -> 'Intel IPU6 CSI2 5':0 [1]" \
        >/dev/null 2>&1 || true
    media-ctl -d "${MEDIA}" \
        -l "'Intel IPU6 CSI2 5':1 -> 'Intel IPU6 ISYS Capture 40':0 [1]" \
        >/dev/null 2>&1 || true
    media-ctl -d "${MEDIA}" \
        -V "'ov01a1s 4-0036':0 [fmt:SGRBG10_1X10/${WIDTH}x${HEIGHT} field:none]" \
        >/dev/null 2>&1 || true
    media-ctl -d "${MEDIA}" \
        -V "'Intel IPU6 CSI2 5':0 [fmt:SGRBG10_1X10/${WIDTH}x${HEIGHT} field:none]" \
        >/dev/null 2>&1 || true
    media-ctl -d "${MEDIA}" \
        -V "'Intel IPU6 CSI2 5':1 [fmt:SGRBG10_1X10/${WIDTH}x${HEIGHT} field:none]" \
        >/dev/null 2>&1 || true

    graph_check="$(media-ctl -p -d "${MEDIA}" 2>/dev/null || true)"
    sensor_check="$(grep -A12 -B3 'ov01a1s 4-0036' <<<"${graph_check}" || true)"
    csi_check="$(grep -A14 -B3 'Intel IPU6 CSI2 5' <<<"${graph_check}" || true)"
    if ! grep -q 'ov01a1s 4-0036' <<<"${graph_check}" ||
       ! grep -q -- 'Intel IPU6 CSI2 5' <<<"${graph_check}"; then
        echo "Erro: o media graph nao mostra o link ov01a1s -> Intel IPU6 CSI2 5." >&2
        echo "O driver esta carregado, mas o pipeline da camera ficou inconsistente." >&2
        echo "Tente reiniciar a sessao ou reiniciar o sistema; depois rode este script antes de abrir GNOME Camera/OBS." >&2
        echo "Para diagnostico:" >&2
        echo "  media-ctl -p -d ${MEDIA} | grep -A12 -B6 'ov01a1s'" >&2
        echo "  sudo dmesg | grep -Ei 'ov01a1s|ipu6|isys|link|stream|failed' | tail -120" >&2
        exit 1
    fi

    if ! grep -q -- '-> "Intel IPU6 CSI2 5":0' <<<"${sensor_check}"; then
        echo "Aviso: nao encontrei o link ov01a1s -> CSI2 5 no bloco do sensor." >&2
        echo "Vou tentar iniciar mesmo assim; se falhar, use o diagnostico abaixo." >&2
        echo "${sensor_check}" >&2
    fi

    if ! grep -q -- '<- "ov01a1s 4-0036":0' <<<"${csi_check}"; then
        echo "Aviso: nao encontrei o link de entrada do ov01a1s no bloco CSI2 5." >&2
        echo "Vou tentar iniciar mesmo assim; se falhar, o graph precisa ser recriado por reboot/modprobe." >&2
    fi
fi

if command -v fuser >/dev/null 2>&1; then
    holders="$(fuser "${INPUT}" "${OUTPUT}" "${MEDIA}" 2>/dev/null || true)"
    if [[ -n "${holders}" ]]; then
        echo "Aviso: algum processo esta com a camera aberta: ${holders}" >&2
        echo "Feche GNOME Camera/OBS antes de iniciar o bridge, depois abra o app novamente." >&2
    fi
fi

rotate_arg=()
if [[ "${ROTATE}" == "no" ]]; then
    rotate_arg=("--no-rotate")
fi

common_args=(
    --input "${INPUT}" \
    --output "${OUTPUT}" \
    --width "${WIDTH}" \
    --height "${HEIGHT}" \
    --fps "${FPS}" \
    --cfa rgbir-yhrn180 \
    --phase-x 0 \
    --phase-y 1 \
    --auto-wb \
    --target-luma "${TARGET_LUMA}" \
    --contrast "${CONTRAST}" \
    --brightness "${BRIGHTNESS}" \
    "${rotate_arg[@]}"
)

if [[ "${FAST}" == "yes" ]]; then
    common_args+=(--fast)
fi

if [[ "${COLOR}" == "yes" ]]; then
    exec "${BRIDGE}" \
        "${common_args[@]}" \
        --ir-subtract "${IR_SUBTRACT}" \
        --saturation "${SATURATION}" \
        --u-gain "${U_GAIN}" \
        --v-gain "${V_GAIN}" \
        --u-offset "${U_OFFSET}" \
        --v-offset "${V_OFFSET}" \
        --hue-deg "${HUE_DEG}"
else
    exec "${BRIDGE}" \
        "${common_args[@]}" \
        --mono
fi
