#!/usr/bin/env bash
#
# Corrige o limite MAX_DEVICES=64 do plugin SPA v4l2 do PipeWire.
#
# O driver Intel IPU6 cria 64+ nos /dev/video (video0..63), enchendo a tabela
# interna do plugin; o /dev/video90 (v4l2loopback) fica de fora e o
# WirePlumber/GNOME Snapshot nunca o veem.
#
# Este script compila o plugin da MESMA versao do PipeWire instalada com
# MAX_DEVICES=256 e o usa via SPA_PLUGIN_DIR (drop-in dos servicos de usuario
# pipewire e wireplumber). Nao altera arquivos do sistema.
#
# Uso: tools/build_patched_spa_v4l2.sh
set -euo pipefail

WORK="${WORK:-$HOME/dev/pipewire-src}"
DEST="${DEST:-$HOME/dev/pipewire-spa-patched}"
SYSTEM_SPA="/usr/lib/x86_64-linux-gnu/spa-0.2"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mERRO: %s\033[0m\n' "$*" >&2; exit 1; }

PWVER="$(pipewire --version 2>/dev/null | awk '/libpipewire/{print $3}')"
[[ -n "${PWVER}" ]] || die "nao consegui detectar a versao do PipeWire"
log "PipeWire instalado: ${PWVER}"

command -v gcc >/dev/null || die "gcc nao encontrado"
[[ -d "${SYSTEM_SPA}" ]] || die "diretorio SPA do sistema nao encontrado: ${SYSTEM_SPA}"

log "Obtendo fontes do PipeWire ${PWVER}"
if [[ ! -d "${WORK}/spa/plugins/v4l2" ]]; then
    rm -rf "${WORK}"
    git clone --depth 1 --branch "${PWVER}" \
        https://gitlab.freedesktop.org/pipewire/pipewire.git "${WORK}"
fi

cd "${WORK}/spa/plugins/v4l2"
sed -i 's/#define MAX_DEVICES\t64/#define MAX_DEVICES\t256/' v4l2-udev.c
grep -q 'MAX_DEVICES\t256' v4l2-udev.c || die "patch do MAX_DEVICES falhou"

printf '#define HAVE_LIBUDEV 1\n#define PACKAGE_VERSION "%s"\n' "${PWVER}" > config.h

log "Compilando libspa-v4l2.so com MAX_DEVICES=256"
gcc -shared -fPIC -O2 -Wall -o /tmp/libspa-v4l2-patched.so \
    v4l2.c v4l2-device.c v4l2-source.c v4l2-udev.c \
    -I. -I../../include -ludev -lm

log "Preparando arvore SPA em ${DEST}"
rm -rf "${DEST}"
mkdir -p "${DEST}"
cp -r "${SYSTEM_SPA}/." "${DEST}/"
cp /tmp/libspa-v4l2-patched.so "${DEST}/v4l2/libspa-v4l2.so"

log "Criando drop-ins dos servicos de usuario"
for svc in pipewire wireplumber; do
    mkdir -p "$HOME/.config/systemd/user/${svc}.service.d"
    cat > "$HOME/.config/systemd/user/${svc}.service.d/spa-patched.conf" <<EOF
[Service]
Environment=SPA_PLUGIN_DIR=${DEST}
EOF
done

systemctl --user daemon-reload
systemctl --user restart pipewire wireplumber
sleep 4

log "Verificacao"
if pw-dump 2>/dev/null | grep -q 'ISP Camera'; then
    echo "OK: a camera virtual apareceu no PipeWire."
else
    echo "AVISO: a camera virtual ainda nao apareceu; verifique 'systemctl --user status wireplumber'." >&2
fi

echo
echo "Pronto. O plugin do sistema NAO foi alterado."
echo "Para desfazer: remova os drop-ins e reinicie os servicos:"
echo "  rm -rf ~/.config/systemd/user/{pipewire,wireplumber}.service.d/spa-patched.conf"
echo "  systemctl --user daemon-reload && systemctl --user restart pipewire wireplumber"
