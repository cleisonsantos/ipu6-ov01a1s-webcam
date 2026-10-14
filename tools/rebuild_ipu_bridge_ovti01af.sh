#!/usr/bin/env bash
set -euo pipefail

kver="$(uname -r)"
src_minor="${kver%%+*}"
src_minor="${src_minor%.*}"
src_dir="/usr/src/linux-source-${src_minor}"
src_tar="/usr/src/linux-source-${src_minor}.tar.xz"
bridge_src="${src_dir}/drivers/media/pci/intel/ipu-bridge.c"
module_dir="/lib/modules/${kver}/kernel/drivers/media/pci/intel"
module_path="${module_dir}/ipu-bridge.ko.xz"
backup_path="${module_path}.bak-$(date +%Y%m%d-%H%M%S)"

echo "Kernel atual: ${kver}"
echo "Fonte esperada: ${src_dir}"

sudo -v

if [[ ! -d "${src_dir}" ]]; then
    if [[ ! -f "${src_tar}" ]]; then
        echo "Erro: nao encontrei ${src_tar}."
        echo "Instale o pacote linux-source correspondente ao kernel atual."
        exit 1
    fi

    echo "Extraindo ${src_tar} em /usr/src..."
    sudo tar -C /usr/src -xf "${src_tar}"
fi

if [[ ! -f "${bridge_src}" ]]; then
    echo "Erro: nao encontrei ${bridge_src}."
    exit 1
fi

if grep -q 'IPU_SENSOR_CONFIG("OVTI01AF"' "${bridge_src}"; then
    echo "ipu-bridge.c ja contem OVTI01AF."
else
    echo "Aplicando OVTI01AF em ipu-bridge.c..."
    sudo sed -i \
        '/IPU_SENSOR_CONFIG("OVTI01AS", 1, 400000000),/a\	IPU_SENSOR_CONFIG("OVTI01AF", 1, 400000000),' \
        "${bridge_src}"
fi

sudo sed -i 's/^\\tIPU_SENSOR_CONFIG/\tIPU_SENSOR_CONFIG/' "${bridge_src}"

echo "Validando patch no fonte:"
grep -n 'OVTI01A0\|OVTI01AS\|OVTI01AF' "${bridge_src}"

echo "Compilando ipu-bridge para ${kver}..."
sudo make -C "/lib/modules/${kver}/build" \
    M="${src_dir}/drivers/media/pci/intel" \
    modules

bridge_ko="${src_dir}/drivers/media/pci/intel/ipu-bridge.ko"
sign_file="/lib/modules/${kver}/build/scripts/sign-file"
mok_key="/var/lib/dkms/mok.key"
mok_cert="/var/lib/dkms/mok.pub"

if [[ -f "${mok_key}" && -f "${mok_cert}" && -x "${sign_file}" ]]; then
    echo "Assinando ipu-bridge.ko com a chave MOK..."
    sudo "${sign_file}" sha256 "${mok_key}" "${mok_cert}" "${bridge_ko}"
    if readelf -S "${bridge_ko}" | grep -q '\.module_sig'; then
        echo "Assinatura MOK aplicada."
    else
        echo "Erro: assinatura nao encontrada no modulo."
        exit 1
    fi
else
    echo "AVISO: MOK ou sign-file ausente; o modulo ficara SEM assinatura e o"
    echo "Secure Boot vai rejeita-lo no modprobe."
fi

echo "Fazendo backup do modulo atual:"
sudo cp -a "${module_path}" "${backup_path}"
echo "Backup: ${backup_path}"

echo "Instalando novo ipu-bridge.ko.xz com CRC32..."
sudo xz -k -f --check=crc32 "${src_dir}/drivers/media/pci/intel/ipu-bridge.ko"
sudo cp -a "${src_dir}/drivers/media/pci/intel/ipu-bridge.ko.xz" "${module_path}"
sudo depmod -a "${kver}"

echo "Confirmando OVTI01AF no modulo instalado:"
xzcat "${module_path}" | strings | grep -E 'OVTI01AF|OVTI01AS|OVTI01A0'

echo
echo "Pronto. Reinicie o sistema e rode:"
echo "  cd ~/dev/webcam"
echo "  ./tools/start_ipu6_webcam_meeting.sh"
