#!/usr/bin/env bash
#
# Compatibilidade Chrome + GNOME para a camera virtual:
#   - v4l2loopback com exclusive_caps=1 (exigido pelo Chrome/WebRTC: ele
#     rejeita dispositivos que expoem captura E saida ao mesmo tempo)
#   - regra udev forcando ID_V4L_CAPABILITIES com :video_capture: para o
#     /dev/video90 (assim o PipeWire/portal/GNOME continuam vendo a camera,
#     mesmo com exclusive_caps=1)
#
# Uso: sudo bash tools/fix_chrome_compat.sh
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Erro: rode com sudo -> sudo bash $0" >&2; exit 1; }

USER_NAME="${SUDO_USER:-$(logname 2>/dev/null || echo css)}"
UID_NUM="$(id -u "${USER_NAME}")"
run_user() {
    sudo -u "${USER_NAME}" \
        XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
        "$@"
}

CONF=/etc/modprobe.d/ipu6-webcam.conf
LOOPBACK="${LOOPBACK:-/dev/video90}"
NODE_NAME="$(basename "${LOOPBACK}")"

echo "== v4l2loopback: exclusive_caps=1 (compatibilidade Chrome/WebRTC)"
if [[ -f "${CONF}" ]]; then
    if grep -q 'exclusive_caps=' "${CONF}"; then
        sed -i 's/exclusive_caps=[01]/exclusive_caps=1/' "${CONF}"
    else
        sed -i 's/^options v4l2loopback/options v4l2loopback exclusive_caps=1/' "${CONF}"
    fi
else
    echo 'options v4l2loopback devices=1 video_nr=90 card_label="IPU6 ISP Camera" exclusive_caps=1' > "${CONF}"
fi
grep exclusive_caps "${CONF}"

echo
echo "== udev: forcar :video_capture: no ${LOOPBACK}"
cat > /etc/udev/rules.d/71-ipu6-loopback-caps.rules <<EOF
# Mantem o loopback visivel como camera para o PipeWire/portal mesmo com
# exclusive_caps=1 (exigido pelo Chrome/WebRTC).
SUBSYSTEM=="video4linux", KERNEL=="${NODE_NAME}", ENV{ID_V4L_CAPABILITIES}=":video_capture:video_output:"
EOF
udevadm control --reload
udevadm trigger --action=change --sysname-match="${NODE_NAME}" || true

echo
echo "== Recarregando o v4l2loopback e reiniciando o pipeline"
run_user systemctl --user stop ipu6-webcam || true
modprobe -r v4l2loopback 2>/dev/null || true
modprobe v4l2loopback
udevadm trigger --action=change --sysname-match="${NODE_NAME}" || true
run_user systemctl --user start ipu6-webcam || true
run_user systemctl --user restart wireplumber || true
sleep 4

echo
echo "== Estado:"
udevadm info "${LOOPBACK}" 2>/dev/null | grep ID_V4L_CAPABILITIES || true
run_user wpctl status 2>/dev/null | sed -n '/Video/,/Filters/p' | head -8

echo
echo "Pronto. No Chrome: chrome://restart e teste de novo."
