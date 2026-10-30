#!/usr/bin/env bash
#
# ipu6-ov01a1s-webcam installer
#
# Instala o suporte completo da webcam Intel IPU6 + sensor OmniVision OV01A1S
# (ACPI OVTI01AF), incluindo:
#   - DKMS do ipu-bridge com o mapeamento ACPI OVTI01AF
#   - DKMS dos drivers Intel IPU6 (sensor ov01a1s)
#   - ipu6-camera-bins (libs do ISP/AIQ)
#   - ipu6-camera-hal (build + install)
#   - icamerasrc (plugin GStreamer)
#   - config do HAL ajustada para esta placa + udev do PSYS
#
# Uso: sudo ./install.sh
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_DIR="/usr/src"
KVER="$(uname -r)"
KMAJOR_MINOR="$(echo "${KVER}" | cut -d. -f1,2)"
export PATH="/usr/sbin:/sbin:${PATH}"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mAVISO: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "rode com sudo: sudo $0"

if ! command -v apt-get >/dev/null 2>&1; then
    die "este instalador suporta apenas Debian/Ubuntu (apt-get nao encontrado)."
fi

log "Kernel: ${KVER} (linux-source-${KMAJOR_MINOR})"

# ---------------------------------------------------------------------------
log "0/8 Verificando hardware"
if ! lspci -nn 2>/dev/null | grep -q '8086:9a19'; then
    warn "Controlador Intel IPU6 Tiger Lake [8086:9a19] nao encontrado."
fi
if ! compgen -G "/sys/bus/i2c/devices/i2c-OVTI01AF:*" >/dev/null 2>&1; then
    warn "Sensor ACPI OVTI01AF nao encontrado. O driver pode nao ter efeito nesta maquina."
fi

# ---------------------------------------------------------------------------
log "1/8 Instalando dependencias"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y \
    build-essential cmake pkg-config autoconf automake libtool git xz-utils \
    dkms kmod v4l-utils mokutil \
    libexpat1-dev libdrm-dev libva-dev \
    libgstreamer1.0-dev libgstreamer-plugins-base1.0-dev libgstreamer-plugins-bad1.0-dev \
    libgudev-1.0-dev libjson-c-dev uuid-dev libx11-dev \
    gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
    "linux-headers-${KVER}" || warn "alguns pacotes falharam; seguindo"

apt-get install -y "linux-source-${KMAJOR_MINOR}" || apt-get install -y linux-source || \
    warn "linux-source nao instalado; o DKMS do ipu-bridge pode falhar"
apt-get install -y v4l2loopback-dkms v4l2loopback-utils || \
    warn "v4l2loopback nao instalado; a saida em /dev/video90 pode falhar"

# ---------------------------------------------------------------------------
log "2/8 ipu6-drivers (DKMS) - sensor ov01a1s"
if compgen -G "/lib/modules/${KVER}/*/ov01a1s.ko*" >/dev/null 2>&1 || \
   compgen -G "/lib/modules/${KVER}/*/*/ov01a1s.ko*" >/dev/null 2>&1; then
    log "ov01a1s ja instalado; pulando"
else
    if [[ ! -d "${SRC_DIR}/ipu6-drivers" ]]; then
        git clone --depth 1 https://github.com/intel/ipu6-drivers "${SRC_DIR}/ipu6-drivers"
    fi
    dkms add "${SRC_DIR}/ipu6-drivers" 2>/dev/null || true
    dkms install ipu6-drivers/0.0.0 -k "${KVER}" --force || dkms autoinstall -k "${KVER}"
fi

# ---------------------------------------------------------------------------
log "3/8 ipu-bridge com OVTI01AF (DKMS)"
SRC_TREE="${SRC_DIR}/linux-source-${KMAJOR_MINOR}"
SRC_TAR="${SRC_DIR}/linux-source-${KMAJOR_MINOR}.tar.xz"
if [[ ! -f "${SRC_TREE}/drivers/media/pci/intel/ipu-bridge.c" ]]; then
    [[ -f "${SRC_TAR}" ]] || die "linux-source nao encontrado em ${SRC_TAR}"
    tar -C "${SRC_DIR}" -xf "${SRC_TAR}"
fi

DKMS_SRC="${SRC_DIR}/ipu-bridge-ovti01af-1.0"
rm -rf "${DKMS_SRC}"
mkdir -p "${DKMS_SRC}"
cp "${SRC_TREE}/drivers/media/pci/intel/ipu-bridge.c" "${DKMS_SRC}/"
if ! grep -q 'IPU_SENSOR_CONFIG("OVTI01AF"' "${DKMS_SRC}/ipu-bridge.c"; then
    sed -i '/IPU_SENSOR_CONFIG("OVTI01AS", 1, 400000000),/a\	IPU_SENSOR_CONFIG("OVTI01AF", 1, 400000000),' \
        "${DKMS_SRC}/ipu-bridge.c"
fi
cp "${REPO_DIR}/dkms/ipu-bridge-ovti01af/Makefile" "${DKMS_SRC}/"
cp "${REPO_DIR}/dkms/ipu-bridge-ovti01af/dkms.conf" "${DKMS_SRC}/"

dkms remove ipu-bridge-ovti01af/1.0 -k "${KVER}" 2>/dev/null || true
dkms add "${DKMS_SRC}"
dkms build ipu-bridge-ovti01af/1.0 -k "${KVER}" --force
dkms install ipu-bridge-ovti01af/1.0 -k "${KVER}" --force

# ---------------------------------------------------------------------------
log "4/8 ipu6-camera-bins (ISP/AIQ)"
BINS="${SRC_DIR}/ipu6-camera-bins"
if [[ ! -d "${BINS}" ]]; then
    git clone --depth 1 https://github.com/intel/ipu6-camera-bins "${BINS}"
fi
(
    cd "${BINS}/lib"
    for f in lib*.so.*; do ln -sf "$f" "${f%.*}"; done
    cp -P lib* /usr/lib/
    cp -r "${BINS}/include/." /usr/include/
    mkdir -p /usr/lib/pkgconfig
    cp -r "${BINS}/lib/pkgconfig/." /usr/lib/pkgconfig/
)
ldconfig

# ---------------------------------------------------------------------------
log "5/8 ipu6-camera-hal (build + install)"
HAL="${SRC_DIR}/ipu6-camera-hal"
if [[ ! -d "${HAL}" ]]; then
    git clone --depth 1 https://github.com/intel/ipu6-camera-hal "${HAL}"
fi
sed -i 's/-Werror/-Wno-error/g' "${HAL}/CMakeLists.txt"
mkdir -p "${HAL}/build"
(
    cd "${HAL}/build"
    cmake \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX=/usr \
        -DCMAKE_INSTALL_LIBDIR=lib \
        -DIPU_VER=ipu6 \
        -DUSE_PG_LITE_PIPE=ON \
        -DBUILD_CAMHAL_ADAPTOR=ON \
        -DBUILD_CAMHAL_PLUGIN=ON \
        ..
    make -j"$(nproc)"
    make install
)

# ---------------------------------------------------------------------------
log "6/8 icamerasrc (plugin GStreamer)"
ICAM="${SRC_DIR}/icamerasrc"
if [[ ! -d "${ICAM}" ]]; then
    git clone --depth 1 -b icamerasrc_slim_api https://github.com/intel/icamerasrc "${ICAM}"
fi
(
    cd "${ICAM}"
    export CHROME_SLIM_CAMHAL=ON
    MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || echo x86_64-linux-gnu)"
    ./autogen.sh
    ./configure --prefix=/usr --libdir="/usr/lib/${MULTIARCH}" --enable-gstdrmformat=yes
    make -j"$(nproc)"
    make install
)
ldconfig

# ---------------------------------------------------------------------------
log "7/8 Config do HAL e permissoes"
# Esta placa roteia o OV01A1S para o CSI2 porta 5 (o profile upstream assume 1).
if [[ -f /etc/camera/ipu6/libcamhal_profile.xml ]]; then
    sed -i 's/ov01a1s-uf-1/ov01a1s-uf-5/' /etc/camera/ipu6/libcamhal_profile.xml
fi

cat > /etc/udev/rules.d/70-ipu6-psys.rules <<'EOF'
SUBSYSTEM=="intel-ipu6-psys", KERNEL=="ipu-psys0", GROUP="video", MODE="0660"
EOF
udevadm control --reload
udevadm trigger --subsystem-match=intel-ipu6-psys || true

mkdir -p /run/camera
chmod 0777 /run/camera
cat > /etc/tmpfiles.d/camera.conf <<'EOF'
d /run/camera 0777 root root -
EOF

cat > /etc/modprobe.d/ipu6-webcam.conf <<'EOF'
options v4l2loopback devices=1 video_nr=90 card_label="IPU6 ISP Camera" exclusive_caps=1
EOF

# Chrome/WebRTC exige exclusive_caps=1; esta regra mantem o loopback visivel
# como camera (capture) para o PipeWire/portal/GNOME mesmo assim.
cat > /etc/udev/rules.d/71-ipu6-loopback-caps.rules <<'EOF'
SUBSYSTEM=="video4linux", KERNEL=="video90", ENV{ID_V4L_CAPABILITIES}=":video_capture:video_output:"
EOF
cat > /etc/modules-load.d/ipu6-webcam.conf <<'EOF'
v4l2loopback
EOF

# ---------------------------------------------------------------------------
log "8/8 Instalando o comando ipu6-webcam-start"
install -m 0755 "${REPO_DIR}/tools/start_ipu6_isp_webcam.sh" /usr/local/bin/ipu6-webcam-start
install -m 0755 "${REPO_DIR}/tools/ipu6-webcam-suspend.py" /usr/local/bin/ipu6-webcam-suspend
install -d /usr/lib/systemd/user
install -m 0644 "${REPO_DIR}/systemd/ipu6-webcam.service" /usr/lib/systemd/user/ipu6-webcam.service
install -m 0644 "${REPO_DIR}/systemd/ipu6-webcam-suspend.service" /usr/lib/systemd/user/ipu6-webcam-suspend.service

if [[ -n "${SUDO_USER:-}" ]]; then
    UID_NUM="$(id -u "${SUDO_USER}")"
    sudo -u "${SUDO_USER}" \
        XDG_RUNTIME_DIR="/run/user/${UID_NUM}" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${UID_NUM}/bus" \
        systemctl --user enable --now ipu6-webcam-suspend 2>/dev/null || \
        warn "habilite o listener manualmente: systemctl --user enable --now ipu6-webcam-suspend"
fi

if command -v mokutil >/dev/null 2>&1 && mokutil --sb-state 2>/dev/null | grep -qi enabled; then
    warn "Secure Boot esta LIGADO. Os modulos DKMS locais precisam estar"
    warn "assinados com uma MOK inscrita, senao o kernel vai rejeita-los."
    warn "Rode: sudo bash ${REPO_DIR}/tools/setup_secureboot_mok.sh"
fi

cat <<'EOF'

======================================================================
Instalacao concluida!

Reinicie para carregar o ipu-bridge e os drivers:
    sudo reboot

Depois rode:
    ipu6-webcam-start

E abra o app de camera escolhendo:
    IPU6 ISP Camera (/dev/video90)

Opcoes:
    FLIP=no ipu6-webcam-start        # se a imagem nao precisar de rotacao
    WIDTH=640 HEIGHT=480 ipu6-webcam-start

Para iniciar automaticamente (opcional):
    systemctl --user enable --now ipu6-webcam

Para pausar a camera no suspend (o driver IPU6 recusa suspend com stream aberto):
    systemctl --user enable --now ipu6-webcam-suspend
======================================================================
EOF
