#!/usr/bin/env bash
# Assina os modulos locais (DKMS + ipu-bridge) com a chave MOK do DKMS,
# para que possam ser carregados com Secure Boot ligado.
#
# Uso:  sudo ./tools/sign_local_modules.sh
set -euo pipefail

kver="$(uname -r)"
sign_file="/lib/modules/${kver}/build/scripts/sign-file"
mok_key="/var/lib/dkms/mok.key"
mok_cert="/var/lib/dkms/mok.pub"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "Erro: rode com sudo (precisa escrever em /lib/modules)."
    exit 1
fi

if [[ ! -f "${mok_key}" || ! -f "${mok_cert}" ]]; then
    echo "Erro: chave MOK nao encontrada (${mok_key} / ${mok_cert})."
    exit 1
fi

if [[ ! -x "${sign_file}" ]]; then
    echo "Erro: sign-file nao encontrado em ${sign_file}."
    exit 1
fi

targets=(
    /lib/modules/"${kver}"/updates/dkms/*.ko.xz
    /lib/modules/"${kver}"/kernel/drivers/media/pci/intel/ipu-bridge.ko.xz
)

for f in "${targets[@]}"; do
    [[ -f "$f" ]] || continue
    tmp="$(mktemp -d)"
    if ! xz -dc "$f" > "${tmp}/mod.ko" 2>/dev/null; then
        echo "skip (nao e xz): $f"
        rm -rf "$tmp"
        continue
    fi
    if readelf -S "${tmp}/mod.ko" 2>/dev/null | grep -q '\.module_sig'; then
        echo "ja assinado: $f"
        rm -rf "$tmp"
        continue
    fi
    echo "assinando: $f"
    "${sign_file}" sha256 "${mok_key}" "${mok_cert}" "${tmp}/mod.ko"
    xz -k -f --check=crc32 "${tmp}/mod.ko"
    cp -a "${tmp}/mod.ko.xz" "$f"
    rm -rf "$tmp"
done

depmod -a "${kver}"
echo "Pronto: modulos assinados e depmod executado."
