#!/usr/bin/env bash
# Assina os modulos DKMS com a chave MOK (para Secure Boot ligado).
#
# Uso: sudo bash tools/setup_secureboot_mok.sh
#
# Se a MOK ainda nao estiver inscrita, o script a importa e pede um reboot
# (tela azul do MOK Manager). Rode o script de novo depois do reboot.
set -euo pipefail

[[ "$(id -u)" -eq 0 ]] || { echo "Erro: rode com sudo -> sudo bash $0" >&2; exit 1; }
export PATH="/usr/sbin:/sbin:${PATH}"

KVER="$(uname -r)"
mok_key="/var/lib/dkms/mok.key"
mok_cert="/var/lib/dkms/mok.pub"

if [[ ! -f "${mok_key}" || ! -f "${mok_cert}" ]]; then
    echo "Chave MOK ausente; gerando com 'dkms generate_mok'..."
    dkms generate_mok
fi

# Corrige o caminho do sign-file (o default do dkms no Debian erra para
# kernels com nome do tipo 7.2.10+deb14).
mkdir -p /etc/dkms/framework.conf.d
cat > /etc/dkms/framework.conf.d/mok-signing.conf <<EOF
sign_file="/lib/modules/\$kernelver/build/scripts/sign-file"
mok_signing_key="${mok_key}"
mok_certificate="${mok_cert}"
EOF

if ! mokutil --list-enrolled 2>/dev/null | grep -q 'DKMS module signing key'; then
    echo
    echo "A chave MOK ainda NAO esta inscrita."
    echo "Importando ${mok_cert}; defina uma senha temporaria."
    mokutil --import "${mok_cert}"
    cat <<'EOF'

Depois de reiniciar, na tela azul do MOK Manager:
  1. Enroll MOK
  2. Continue
  3. Yes
  4. digite a senha definida acima
  5. Reboot

Depois do reboot, rode de novo:
  sudo bash tools/setup_secureboot_mok.sh
EOF
    exit 0
fi

echo "MOK inscrita. Assinando os modulos locais..."
exec "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sign_local_modules.sh"
