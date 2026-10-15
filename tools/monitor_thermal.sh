#!/usr/bin/env bash
# Monitora temperatura e RPM da ventoinha (EC INTC1044 / acpi_fan).
#
# Uso: tools/monitor_thermal.sh [intervalo_segundos]
set -euo pipefail

INTERVAL="${1:-2}"
FAN_RPM="/sys/bus/acpi/devices/INTC1044:00/fan_speed_rpm"

if [[ ! -r "${FAN_RPM}" ]]; then
    echo "Aviso: ${FAN_RPM} nao encontrado; mostrando apenas temperaturas." >&2
fi

while true; do
    temps=""
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat "$z/type" 2>/dev/null || true)
        case "$t" in
            x86_pkg_temp|TCPU|acpitz)
                temps+="$t=$(($(cat "$z/temp" 2>/dev/null || echo 0) / 1000))C "
                ;;
        esac
    done
    rpm="?"
    [[ -r "${FAN_RPM}" ]] && rpm=$(cat "${FAN_RPM}" 2>/dev/null || echo '?')
    printf '%s| fan=%s RPM\n' "${temps}" "${rpm}"
    sleep "${INTERVAL}"
done
