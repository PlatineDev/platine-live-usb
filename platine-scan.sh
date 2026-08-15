#!/usr/bin/env bash
# ============================================================
#  PLATINE LIVE USB — Hardware Scanner v2.2.0
#  github.com/platinedev/platine-live-usb
#  platine.dev
#
#  Boot from USB on any PC/laptop — full hardware scan
#  streamed live to your phone via platine.dev
#
#  Usage: sudo bash platine-scan.sh [--silent] [--output=FILE]
#  Output: /tmp/platine_map.json
# ============================================================

set -uo pipefail

PLATINE_VERSION="2.2.0"
SCANNED_AT=$(date '+%Y-%m-%dT%H:%M:%S')
SCAN_START=$SECONDS
SCAN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-8 | tr '[:lower:]' '[:upper:]' 2>/dev/null \
          || printf '%08X' "$$")
OUTPUT_FILE="/tmp/platine_map.json"
SILENT=false
PLATINE_API="https://platine.dev/api/live"

for arg in "$@"; do
    case "$arg" in
        --silent)   SILENT=true ;;
        --output=*) OUTPUT_FILE="${arg#*=}" ;;
    esac
done

# ── Auto-update (si hay red disponible y el USB es escribible) ─
auto_update() {
    command -v curl >/dev/null 2>&1 || return 0
    local SCRIPT_PATH; SCRIPT_PATH=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [ -w "$SCRIPT_PATH" ] || return 0
    local LATEST
    LATEST=$(curl -sf --max-time 5 "${PLATINE_API%/live}/scanner/version" 2>/dev/null \
             | grep -oP '"version":"\K[^"]+' || echo "")
    [ -z "${LATEST:-}" ] && return 0
    [ "$LATEST" = "$PLATINE_VERSION" ] && return 0
    local NEW_SCRIPT
    NEW_SCRIPT=$(curl -sf --max-time 30 "${PLATINE_API%/live}/scanner/download" 2>/dev/null || echo "")
    [ -z "${NEW_SCRIPT:-}" ] && return 0
    printf '%s\n' "$NEW_SCRIPT" > "${SCRIPT_PATH}.new"
    chmod +x "${SCRIPT_PATH}.new"
    mv "${SCRIPT_PATH}.new" "$SCRIPT_PATH"
    [ "$SILENT" = false ] && printf '\033[0;36m  ✓ Scanner actualizado a %s — reiniciando...\033[0m\n' "$LATEST"
    exec "$SCRIPT_PATH" "$@"
}
# Solo intentar auto-update si hay conexión activa (comprobación rápida)
ip route 2>/dev/null | grep -q default && auto_update "$@" || true

# ── Temp dir ──────────────────────────────────────────────────
TMPD=$(mktemp -d /tmp/platine_scan_XXXXXX)
trap 'rm -rf "$TMPD"' EXIT

# ── Colors ────────────────────────────────────────────────────
if [ "$SILENT" = true ]; then
    R='' Y='' G='' C='' W='' D='' N='' B=''
else
    R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m'
    C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m' B='\033[1m'
fi

# ── Helpers ───────────────────────────────────────────────────
cmd() { command -v "$1" >/dev/null 2>&1; }

jstr() {
    local v="${1:-}"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/ }"
    v="${v//$'\r'/}"
    v="${v//	/ }"
    printf '"%s"' "$v"
}

jnum() {
    local v="${1:-}"
    v="${v// /}"
    [ -z "$v" ] && { printf 'null'; return; }
    awk -v n="$v" 'BEGIN{
        if (n ~ /^-?[0-9]+(\.[0-9]+)?$/) printf "%s", n+0
        else printf "null"
    }' 2>/dev/null || printf 'null'
}

jbool() { [ "${1:-false}" = "true" ] && printf 'true' || printf 'false'; }

# add_problem severity component title cause action probfile
add_problem() {
    printf '{"severity":%s,"component":%s,"title":%s,"cause":%s,"action":%s}\n' \
        "$(jstr "${1:-}")" "$(jstr "${2:-}")" "$(jstr "${3:-}")" \
        "$(jstr "${4:-}")" "$(jstr "${5:-}")" >> "${6:-$TMPD/probs_misc.ndjson}"
}

# ── Module status tracking ────────────────────────────────────
MODULES="cpu ram storage battery gpu network thermals audio usb os security android netspeed ios"
st_set()  { printf '%s\n' "$2" > "$TMPD/status_$1"; }
st_get()  { cat "$TMPD/status_$1" 2>/dev/null || printf 'pending'; }
sum_set() { printf '%s\n' "$2" > "$TMPD/summary_$1"; }
sum_get() { cat "$TMPD/summary_$1" 2>/dev/null || printf '—'; }

for _m in $MODULES; do st_set "$_m" "pending"; done

# ── Terminal UI ───────────────────────────────────────────────
render_ui() {
    [ "$SILENT" = true ] && return
    local done_count=0 total=0 active_module="" _m s

    for _m in $MODULES; do
        total=$((total + 1))
        s=$(st_get "$_m")
        case "$s" in
            done|error) done_count=$((done_count + 1)) ;;
            running) active_module="$_m" ;;
        esac
    done

    local pct bar="" i
    pct=$(( total > 0 ? done_count * 100 / total : 0 ))
    local bar_done=$(( pct * 20 / 100 ))
    local bar_rest=$(( 20 - bar_done ))
    i=0; while [ $i -lt $bar_done ]; do bar="${bar}█"; i=$((i+1)); done
    i=0; while [ $i -lt $bar_rest ]; do bar="${bar}─"; i=$((i+1)); done

    printf '\033[H\033[2J'
    printf "${W}  ─────────────────────────────────────────────────────${N}\n"
    printf "${W}  Platine Live USB v%-6s — Alpine Linux${N}\n" "$PLATINE_VERSION"
    printf "${W}  ─────────────────────────────────────────────────────${N}\n\n"

    local machine_line
    machine_line=$(cat "$TMPD/machine_line" 2>/dev/null || echo "")
    [ -n "$machine_line" ] && printf "  ${C}%s${N}\n\n" "$machine_line"

    printf "  ${W}[%s]${N} ${B}%d%%${N}" "$bar" "$pct"
    if [ -n "$active_module" ]; then
        printf "  Scanning %s..." "$active_module"
    else
        printf "  Complete"
    fi
    printf "\n\n"

    for _m in $MODULES; do
        local icon summ label
        s=$(st_get "$_m")
        summ=$(sum_get "$_m")
        label=$(printf '%-10s' "$_m")
        case "$s" in
            done)    icon="${G}✓${N}" ;;
            running) icon="${Y}⟳${N}" ;;
            error)   icon="${R}✗${N}" ;;
            *)       icon="${D}·${N}" ;;
        esac
        printf "  %b %-10s %s\n" "$icon" "$label" "$summ"
    done
    printf "\n"
}

# ── Network Setup (usb0 first — phone tethering) ──────────────
setup_network() {
    printf 'nameserver 8.8.8.8\nnameserver 1.1.1.1\n' > /etc/resolv.conf 2>/dev/null || true
    local iface
    for iface in usb0 usb1 eth0 enp0s3 enp1s0 enp2s0 eno1 wlan0 wlp2s0 wlp3s0; do
        ip link show "$iface" >/dev/null 2>&1 || continue
        ip link set "$iface" up 2>/dev/null || true
        if udhcpc -i "$iface" -t 5 -T 2 -q 2>/dev/null; then
            printf '%s' "$iface" > "$TMPD/net_iface_used"
            return 0
        fi
    done
    return 1
}

# ── Machine identity (fast — needed for UI header) ────────────
scan_machine() {
    local VENDOR="" MODEL="" SERIAL="" UUID="" CHASSIS="" BIOS_VER="" BIOS_DATE=""

    if cmd dmidecode; then
        VENDOR=$(dmidecode -s system-manufacturer   2>/dev/null | head -1 | xargs 2>/dev/null || true)
        MODEL=$(dmidecode -s system-product-name    2>/dev/null | head -1 | xargs 2>/dev/null || true)
        SERIAL=$(dmidecode -s system-serial-number  2>/dev/null | head -1 | xargs 2>/dev/null || true)
        UUID=$(dmidecode -s system-uuid             2>/dev/null | head -1 | xargs 2>/dev/null || true)
        CHASSIS=$(dmidecode -s chassis-type         2>/dev/null | head -1 | xargs 2>/dev/null || true)
        BIOS_VER=$(dmidecode -s bios-version        2>/dev/null | head -1 | xargs 2>/dev/null || true)
        BIOS_DATE=$(dmidecode -s bios-release-date  2>/dev/null | head -1 | xargs 2>/dev/null || true)
    fi
    [ -z "$VENDOR" ]   && VENDOR=$(cat /sys/class/dmi/id/sys_vendor     2>/dev/null | xargs 2>/dev/null || true)
    [ -z "$MODEL" ]    && MODEL=$(cat /sys/class/dmi/id/product_name    2>/dev/null | xargs 2>/dev/null || true)
    [ -z "$CHASSIS" ]  && CHASSIS=$(cat /sys/class/dmi/id/chassis_type  2>/dev/null || true)
    [ -z "$BIOS_VER" ] && BIOS_VER=$(cat /sys/class/dmi/id/bios_version 2>/dev/null | xargs 2>/dev/null || true)

    printf '%s'  "${VENDOR:-}"  > "$TMPD/machine_vendor"
    printf '%s'  "${MODEL:-}"   > "$TMPD/machine_model"
    printf '%s'  "${CHASSIS:-}" > "$TMPD/machine_chassis"
    printf '%s · BIOS %s' "${VENDOR:-Unknown} ${MODEL:-}" "${BIOS_VER:-?}" > "$TMPD/machine_line"

    # BIOS age warning
    local BIOS_AGE_YEARS=""
    if [ -n "${BIOS_DATE:-}" ]; then
        local bios_year
        bios_year=$(echo "$BIOS_DATE" | grep -oP '\b(19|20)[0-9]{2}\b' | head -1 || echo "")
        if [ -n "${bios_year:-}" ]; then
            BIOS_AGE_YEARS=$(( $(date +%Y) - bios_year ))
            if [ "${BIOS_AGE_YEARS:-0}" -ge 5 ]; then
                add_problem "warning" "machine" "BIOS is ${BIOS_AGE_YEARS} years old — security risk" \
                    "BIOS ${BIOS_VER:-?} dated ${BIOS_DATE}" \
                    "Update BIOS from manufacturer website for security patches." \
                    "$TMPD/probs_machine.ndjson"
            elif [ "${BIOS_AGE_YEARS:-0}" -ge 3 ]; then
                add_problem "warning" "machine" "BIOS update recommended (${BIOS_AGE_YEARS} years old)" \
                    "BIOS ${BIOS_VER:-?} dated ${BIOS_DATE}" \
                    "Check manufacturer website for BIOS updates." \
                    "$TMPD/probs_machine.ndjson"
            fi
        fi
    fi

    cat > "$TMPD/json_machine.json" <<JSON
{
  "manufacturer": $(jstr "${VENDOR:-}"),
  "model": $(jstr "${MODEL:-}"),
  "serial": $(jstr "${SERIAL:-}"),
  "uuid": $(jstr "${UUID:-}"),
  "chassis_type": $(jstr "${CHASSIS:-}"),
  "bios_version": $(jstr "${BIOS_VER:-}"),
  "bios_date": $(jstr "${BIOS_DATE:-}"),
  "bios_age_years": $(jnum "${BIOS_AGE_YEARS:-}")
}
JSON
}

# ── Scan: CPU ─────────────────────────────────────────────────
scan_cpu() {
    st_set cpu running
    local pfile="$TMPD/probs_cpu.ndjson"

    local CPU_MODEL CPU_CORES CPU_THREADS CPU_SOCKETS CPU_ARCH CPU_VENDOR CPU_FLAGS
    CPU_MODEL=$(grep -m1 '^model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs 2>/dev/null || echo "Unknown")
    CPU_CORES=$(grep '^cpu cores' /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}' || echo "")
    [ -z "${CPU_CORES:-}" ] && CPU_CORES=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "1")
    CPU_THREADS=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo "1")
    CPU_SOCKETS=$(grep '^physical id' /proc/cpuinfo 2>/dev/null | sort -u | wc -l 2>/dev/null || echo "1")
    CPU_ARCH=$(uname -m 2>/dev/null || echo "")
    CPU_VENDOR=$(grep -m1 '^vendor_id' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs 2>/dev/null || echo "")
    CPU_FLAGS=$(grep -m1 '^flags' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs 2>/dev/null | \
                tr ' ' ',' | cut -c1-300 || echo "")

    local CPU_CUR_MHZ="" CPU_MAX_MHZ="" CPU_BASE_MHZ=""
    CPU_CUR_MHZ=$(grep -m1 '^cpu MHz' /proc/cpuinfo 2>/dev/null | awk '{printf "%.0f",$NF}' || echo "")
    CPU_MAX_MHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null | \
                  awk '{printf "%.0f",$1/1000}' || echo "")
    CPU_BASE_MHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/base_frequency 2>/dev/null | \
                   awk '{printf "%.0f",$1/1000}' 2>/dev/null || \
                   cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_base_freq 2>/dev/null | \
                   awk '{printf "%.0f",$1/1000}' 2>/dev/null || echo "")

    local CPU_L1D="" CPU_L1I="" CPU_L2="" CPU_L3=""
    if cmd lscpu; then
        local lscpu_out
        lscpu_out=$(lscpu 2>/dev/null || echo "")
        CPU_L1D=$(echo "$lscpu_out" | grep -i '^L1d '  | awk '{print $3$4}' || echo "")
        CPU_L1I=$(echo "$lscpu_out" | grep -i '^L1i '  | awk '{print $3$4}' || echo "")
        CPU_L2=$(echo "$lscpu_out"  | grep -iE '^L2 '  | awk '{print $3$4}' || echo "")
        CPU_L3=$(echo "$lscpu_out"  | grep -iE '^L3 '  | awk '{print $3$4}' || echo "")
    fi
    [ -z "$CPU_L2" ] && CPU_L2=$(cat /sys/devices/system/cpu/cpu0/cache/index2/size 2>/dev/null || echo "")
    [ -z "$CPU_L3" ] && CPU_L3=$(cat /sys/devices/system/cpu/cpu0/cache/index3/size 2>/dev/null || echo "")

    # Per-core temps via hwmon
    local CPU_TEMP="" PER_CORE_TEMPS="" hwmon hname tf lbl tc
    for hwmon in /sys/class/hwmon/hwmon*/; do
        [ -d "$hwmon" ] || continue
        hname=$(cat "${hwmon}name" 2>/dev/null || echo "")
        echo "$hname" | grep -qiE "coretemp|k10temp|zenpower|acpitz" || continue
        for tf in "${hwmon}"temp*_input; do
            [ -f "$tf" ] || continue
            lbl=$(cat "${tf/_input/_label}" 2>/dev/null || echo "")
            tc=$(awk '{printf "%.1f",$1/1000}' "$tf" 2>/dev/null || echo "")
            [ -z "$tc" ] && continue
            if echo "$lbl" | grep -qiE "^Package|^Tdie|^CPU$|^CPU Temperature$"; then
                CPU_TEMP="$tc"
            elif echo "$lbl" | grep -qiE "^Core [0-9]|^Tccd[0-9]|^CPU Core [0-9]"; then
                PER_CORE_TEMPS="${PER_CORE_TEMPS}$(jnum "$tc"),"
            fi
        done
        [ -n "$CPU_TEMP" ] && break
    done
    [ -z "$CPU_TEMP" ] && CPU_TEMP=$(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null | \
                                     awk '{printf "%.1f",$1/1000}' 2>/dev/null || echo "")
    PER_CORE_TEMPS="${PER_CORE_TEMPS%,}"

    # Throttle detection — thermal + power limit (RAPL)
    local THROTTLE_ACTIVE="false" THROTTLE_REASON="" THROTTLE_COUNT="0"
    local RAPL_LIMIT_W="" RAPL_POWER_LIMIT_ACTIVE="false"

    THROTTLE_COUNT=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo "0")
    if [ "${THROTTLE_COUNT:-0}" -gt 0 ] 2>/dev/null; then
        THROTTLE_ACTIVE="true"; THROTTLE_REASON="thermal"
    fi

    # Intel RAPL — detectar power limit activo
    for rapl_zone in /sys/class/powercap/intel-rapl/intel-rapl:0 \
                     /sys/class/powercap/intel-rapl:0; do
        [ -f "${rapl_zone}/constraint_0_power_limit_uw" ] || continue
        RAPL_LIMIT_W=$(awk '{printf "%.1f",$1/1000000}' \
            "${rapl_zone}/constraint_0_power_limit_uw" 2>/dev/null || echo "")
        # Si el power limit es muy bajo comparado con el TDP nominal → throttle por power
        local TDP_EST
        TDP_EST=$(awk -v c="${CPU_CORES:-4}" 'BEGIN{printf "%.0f", c * 4.5}' 2>/dev/null || echo "0")
        if [ -n "${RAPL_LIMIT_W:-}" ] && [ -n "${TDP_EST:-}" ]; then
            if awk -v l="${RAPL_LIMIT_W}" -v t="${TDP_EST}" 'BEGIN{exit !(l+0 < t*0.7)}' 2>/dev/null; then
                RAPL_POWER_LIMIT_ACTIVE="true"
            fi
        fi
        break
    done

    # Heurística de frecuencia: si corre <60% del boost y temp no está alta → power limit
    if [ -n "${CPU_CUR_MHZ:-}" ] && [ -n "${CPU_MAX_MHZ:-}" ] && [ "${CPU_MAX_MHZ:-0}" -gt 0 ] 2>/dev/null; then
        local ratio
        ratio=$(awk -v c="${CPU_CUR_MHZ}" -v m="${CPU_MAX_MHZ}" \
            'BEGIN{if(m>0) printf "%.0f",c*100/m; else print 100}' 2>/dev/null || echo "100")
        if [ "${ratio:-100}" -lt 60 ] 2>/dev/null; then
            THROTTLE_ACTIVE="true"
            if [ -n "${CPU_TEMP:-}" ] && awk -v t="${CPU_TEMP}" 'BEGIN{exit !(t+0>85)}' 2>/dev/null; then
                THROTTLE_REASON="thermal"
            elif [ "$RAPL_POWER_LIMIT_ACTIVE" = "true" ]; then
                THROTTLE_REASON="power_limit_rapl"
            else
                THROTTLE_REASON="${THROTTLE_REASON:-power_limit}"
            fi
        fi
    fi

    if [ "$THROTTLE_ACTIVE" = "true" ]; then
        add_problem "warning" "cpu" "CPU throttling detected" \
            "Throttle reason: ${THROTTLE_REASON:-unknown} (event count: $THROTTLE_COUNT)" \
            "Check cooling system and power delivery. Clean heatsink if thermal." "$pfile"
    fi
    if [ -n "${CPU_TEMP:-}" ] && awk -v t="${CPU_TEMP}" 'BEGIN{exit !(t+0>95)}' 2>/dev/null; then
        add_problem "critical" "cpu" "CPU temperature critical" \
            "CPU at ${CPU_TEMP}°C — threshold 95°C" \
            "Shut down immediately. Replace thermal paste and check heatsink." "$pfile"
    elif [ -n "${CPU_TEMP:-}" ] && awk -v t="${CPU_TEMP}" 'BEGIN{exit !(t+0>85)}' 2>/dev/null; then
        add_problem "warning" "cpu" "CPU temperature high" \
            "CPU at ${CPU_TEMP}°C — threshold 85°C" \
            "Check cooling. Clean heatsink vents." "$pfile"
    fi

    local summ="${CPU_MODEL} · ${CPU_CORES}C/${CPU_THREADS}T"
    [ -n "${CPU_TEMP:-}" ] && summ="${summ} · ${CPU_TEMP}°C"
    [ "$THROTTLE_ACTIVE" = "true" ] && summ="${summ} ⚠ THROTTLE"
    sum_set cpu "$summ"

    cat > "$TMPD/json_cpu.json" <<JSON
{
  "model": $(jstr "$CPU_MODEL"),
  "vendor": $(jstr "${CPU_VENDOR:-}"),
  "architecture": $(jstr "${CPU_ARCH:-}"),
  "cores": $(jnum "${CPU_CORES:-}"),
  "threads": $(jnum "${CPU_THREADS:-}"),
  "sockets": $(jnum "${CPU_SOCKETS:-}"),
  "current_mhz": $(jnum "${CPU_CUR_MHZ:-}"),
  "base_mhz": $(jnum "${CPU_BASE_MHZ:-}"),
  "max_mhz": $(jnum "${CPU_MAX_MHZ:-}"),
  "temp_c": $(jnum "${CPU_TEMP:-}"),
  "per_core_temps_c": [${PER_CORE_TEMPS:-}],
  "throttle_active": $(jbool "$THROTTLE_ACTIVE"),
  "throttle_reason": $(jstr "${THROTTLE_REASON:-}"),
  "throttle_count": $(jnum "${THROTTLE_COUNT:-0}"),
  "rapl_limit_w": $(jnum "${RAPL_LIMIT_W:-}"),
  "cache": {
    "l1d": $(jstr "${CPU_L1D:-}"),
    "l1i": $(jstr "${CPU_L1I:-}"),
    "l2": $(jstr "${CPU_L2:-}"),
    "l3": $(jstr "${CPU_L3:-}")
  },
  "flags": $(jstr "${CPU_FLAGS:-}")
}
JSON
    st_set cpu done
}

# ── Scan: RAM ─────────────────────────────────────────────────
scan_ram() {
    st_set ram running
    local pfile="$TMPD/probs_ram.ndjson"

    local total_kb free_kb TOTAL_GB AVAILABLE_GB
    total_kb=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    free_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null || echo "0")
    TOTAL_GB=$(awk -v t="$total_kb" 'BEGIN{printf "%.1f",t/1024/1024}' 2>/dev/null || echo "0")
    AVAILABLE_GB=$(awk -v f="$free_kb" 'BEGIN{printf "%.1f",f/1024/1024}' 2>/dev/null || echo "0")

    local MAX_SPEED="" CONFIG_SPEED="" XMP_AVAILABLE="false" XMP_ENABLED="false"
    local HAS_LPDDR="false" slots="" SLOTS_JSON="[]"

    if cmd dmidecode; then
        local dmi_out
        dmi_out=$(dmidecode -t 17 2>/dev/null || echo "")

        MAX_SPEED=$(echo "$dmi_out" | grep -E '^\s+Speed:' | \
                    grep -v 'Unknown\|No Module\|Not Specified' | \
                    grep -oP '[0-9]+' | sort -rn | head -1 || echo "")
        CONFIG_SPEED=$(echo "$dmi_out" | grep -iE 'Configured.*Speed:|Configured.*Clock:' | \
                       grep -oP '[0-9]+' | head -1 || echo "")

        if [ -n "${MAX_SPEED:-}" ] && [ -n "${CONFIG_SPEED:-}" ]; then
            [ "$MAX_SPEED" -gt "$CONFIG_SPEED" ] 2>/dev/null && XMP_AVAILABLE="true"
            [ "$MAX_SPEED" -le "$(( CONFIG_SPEED + 10 ))" ] 2>/dev/null && XMP_ENABLED="true"
        fi

        echo "$dmi_out" | grep -qiE "LPDDR|Row Of Chips" && HAS_LPDDR="true"

        # Per-slot parsing via awk paragraph mode
        while IFS= read -r block; do
            echo "$block" | grep -q "Memory Device" || continue
            local sz
            sz=$(echo "$block" | grep '^\s*Size:' | head -1 | \
                 grep -oP '[0-9]+\s*(GB|MB)' | head -1 || echo "")
            [ -z "$sz" ] && continue
            echo "$sz" | grep -qP '^\d' || continue

            local loc typ spd cspd fff prt mfr
            loc=$(echo "$block"  | grep '^\s*Locator:'         | grep -v 'Bank' | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")
            typ=$(echo "$block"  | grep '^\s*Type:'            | grep -v 'Error\|Factor\|Detail' | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")
            spd=$(echo "$block"  | grep '^\s*Speed:'           | head -1 | grep -oP '[0-9]+' | head -1 || echo "")
            cspd=$(echo "$block" | grep -i 'Configured.*Speed:'| head -1 | grep -oP '[0-9]+' | head -1 || echo "")
            fff=$(echo "$block"  | grep '^\s*Form Factor:'     | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")
            prt=$(echo "$block"  | grep '^\s*Part Number:'     | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")
            mfr=$(echo "$block"  | grep '^\s*Manufacturer:'    | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")

            echo "${typ:-}${fff:-}" | grep -qiE "LPDDR|Row" && HAS_LPDDR="true"

            slots="${slots}{\"locator\":$(jstr "${loc:-}"),\"size\":$(jstr "${sz:-}"),\"type\":$(jstr "${typ:-}"),\"speed_mhz\":$(jnum "${spd:-}"),\"configured_mhz\":$(jnum "${cspd:-}"),\"form_factor\":$(jstr "${fff:-}"),\"part\":$(jstr "${prt:-}"),\"manufacturer\":$(jstr "${mfr:-}")},"
        done < <(echo "$dmi_out" | awk 'BEGIN{RS="\n\n";ORS="\n\n"}{print}')

        SLOTS_JSON="[${slots%,}]"
    fi

    if [ "$XMP_AVAILABLE" = "true" ] && [ "$XMP_ENABLED" = "false" ]; then
        add_problem "warning" "ram" "XMP/EXPO profile not enabled" \
            "RAM rated at ${MAX_SPEED} MT/s but running at ${CONFIG_SPEED} MT/s" \
            "Enable XMP or EXPO in BIOS/UEFI settings for rated performance." "$pfile"
    fi

    local summ="${TOTAL_GB}GB RAM"
    [ -n "${MAX_SPEED:-}" ] && summ="${summ} · ${MAX_SPEED} MT/s"
    [ "$XMP_AVAILABLE" = "true" ] && [ "$XMP_ENABLED" = "false" ] && summ="${summ} ⚠ XMP OFF"
    [ "$HAS_LPDDR" = "true" ] && summ="${summ} · LPDDR"
    sum_set ram "$summ"

    cat > "$TMPD/json_ram.json" <<JSON
{
  "total_gb": $(jnum "$TOTAL_GB"),
  "available_gb": $(jnum "$AVAILABLE_GB"),
  "speed_mhz": $(jnum "${MAX_SPEED:-}"),
  "configured_mhz": $(jnum "${CONFIG_SPEED:-}"),
  "xmp_available": $(jbool "$XMP_AVAILABLE"),
  "xmp_enabled": $(jbool "$XMP_ENABLED"),
  "is_lpddr": $(jbool "$HAS_LPDDR"),
  "slots": $SLOTS_JSON
}
JSON
    st_set ram done
}

# ── Scan: Storage ─────────────────────────────────────────────
scan_storage() {
    st_set storage running
    local pfile="$TMPD/probs_storage.ndjson"
    local drives_json="" drive_count=0 issue_count=0

    for dev in /dev/sd? /dev/nvme?n? /dev/mmcblk?; do
        [ -b "$dev" ] || continue
        drive_count=$((drive_count + 1))

        local DTYPE SIZE_GB MODEL SERIAL SMART_HEALTH POWER_HOURS="" TEMP_C=""
        local REALLOCATED="0" PENDING="0" UNCORRECTABLE="0"
        local NVME_SPARE="" NVME_PCT_USED="" NVME_UNSAFE_SHUT="" NVME_POWER_CYCLES=""
        local attrs_json="" READ_SPEED_MBPS=""

        case "$dev" in
            /dev/nvme*)   DTYPE="NVMe" ;;
            /dev/mmcblk*) DTYPE="eMMC" ;;
            *)
                local rota
                rota=$(cat "/sys/block/$(basename "$dev")/queue/rotational" 2>/dev/null || echo "0")
                [ "$rota" = "1" ] && DTYPE="HDD" || DTYPE="SSD"
                ;;
        esac

        SIZE_GB=$(lsblk -bdn -o SIZE "$dev" 2>/dev/null | \
                  awk '{printf "%.0f",$1/1024/1024/1024}' 2>/dev/null || echo "")
        MODEL=$(cat "/sys/block/$(basename "$dev")/device/model" 2>/dev/null | xargs 2>/dev/null || echo "")
        SERIAL=$(cat "/sys/block/$(basename "$dev")/device/serial" 2>/dev/null | xargs 2>/dev/null || echo "")
        SMART_HEALTH=""

        if cmd smartctl; then
            local SOUT
            SOUT=$(smartctl -a "$dev" 2>/dev/null || echo "")
            if [ -n "$SOUT" ]; then
                local m; m=$(echo "$SOUT" | grep -iE '^Device Model|^Model Number' | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")
                [ -n "$m" ] && MODEL="$m"
                local ser; ser=$(echo "$SOUT" | grep -i '^Serial Number' | head -1 | cut -d: -f2 | xargs 2>/dev/null || echo "")
                [ -n "$ser" ] && SERIAL="$ser"
                SMART_HEALTH=$(echo "$SOUT" | grep -iE 'overall-health|SMART Health Status' | \
                               head -1 | awk '{print $NF}' || echo "")

                if [ "$DTYPE" = "NVMe" ]; then
                    NVME_SPARE=$(echo "$SOUT"       | grep -i "Available Spare:"   | grep -oP '[0-9]+' | head -1 || echo "")
                    NVME_PCT_USED=$(echo "$SOUT"    | grep -i "Percentage Used:"   | grep -oP '[0-9]+' | head -1 || echo "")
                    NVME_UNSAFE_SHUT=$(echo "$SOUT" | grep -i "Unsafe Shutdowns:"  | grep -oP '[0-9]+' | head -1 || echo "")
                    NVME_POWER_CYCLES=$(echo "$SOUT"| grep -i "Power Cycles:"      | grep -oP '[0-9]+' | head -1 || echo "")
                    TEMP_C=$(echo "$SOUT"           | grep -iE "^Temperature:"     | grep -oP '[0-9]+' | head -1 || echo "")
                    POWER_HOURS=$(echo "$SOUT"      | grep -i "Power On Hours:"    | grep -oP '[0-9,]+' | head -1 | tr -d ',' || echo "")

                    if [ -n "${NVME_PCT_USED:-}" ] && [ "${NVME_PCT_USED:-0}" -ge 90 ] 2>/dev/null; then
                        issue_count=$((issue_count + 1))
                        add_problem "critical" "storage" "NVMe wear critical — $(basename "$dev")" \
                            "Drive life used: ${NVME_PCT_USED}%" \
                            "Backup all data immediately. Replace NVMe drive." "$pfile"
                    elif [ -n "${NVME_PCT_USED:-}" ] && [ "${NVME_PCT_USED:-0}" -ge 70 ] 2>/dev/null; then
                        add_problem "warning" "storage" "NVMe nearing end of life — $(basename "$dev")" \
                            "Drive life used: ${NVME_PCT_USED}%" \
                            "Plan for drive replacement soon." "$pfile"
                    fi
                    if [ -n "${NVME_SPARE:-}" ] && [ "${NVME_SPARE:-100}" -lt 10 ] 2>/dev/null; then
                        issue_count=$((issue_count + 1))
                        add_problem "critical" "storage" "NVMe spare space critical — $(basename "$dev")" \
                            "Available spare: ${NVME_SPARE}% (threshold: 10%)" \
                            "Replace drive immediately." "$pfile"
                    fi
                else
                    # SATA/SSD — full attribute table with thresh field (up to 40 rows)
                    REALLOCATED=$(echo "$SOUT" | awk '/^\s*5\s+/{print $10}' | head -1 || echo "0")
                    PENDING=$(echo "$SOUT"     | awk '/^\s*197\s+/{print $10}' | head -1 || echo "0")
                    UNCORRECTABLE=$(echo "$SOUT"| awk '/^\s*198\s+/{print $10}' | head -1 || echo "0")
                    POWER_HOURS=$(echo "$SOUT"  | awk '/^\s*9\s+/{print $10}'   | head -1 | tr -d ',' || echo "")
                    TEMP_C=$(echo "$SOUT"       | awk '/^\s*(190|194)\s+/{print $10}' | head -1 || echo "")

                    while IFS= read -r row; do
                        [ -z "$row" ] && continue
                        local aid aname aval aw ath atype araw
                        aid=$(echo "$row"   | awk '{print $1}')
                        aname=$(echo "$row" | awk '{print $2}')
                        aval=$(echo "$row"  | awk '{print $4}')
                        aw=$(echo "$row"    | awk '{print $5}')
                        ath=$(echo "$row"   | awk '{print $6}')
                        atype=$(echo "$row" | awk '{print $7}')
                        araw=$(echo "$row"  | awk '{print $10}')
                        attrs_json="${attrs_json}{\"id\":$(jnum "$aid"),\"name\":$(jstr "$aname"),\"value\":$(jnum "$aval"),\"worst\":$(jnum "$aw"),\"thresh\":$(jnum "$ath"),\"type\":$(jstr "$atype"),\"raw\":$(jnum "$araw")},"
                    done < <(echo "$SOUT" | grep -E '^\s+[0-9]+ [A-Za-z_]' | head -40 || true)

                    if [ "${REALLOCATED:-0}" -ge 1 ] 2>/dev/null; then
                        issue_count=$((issue_count + 1))
                        add_problem "critical" "storage" "Drive failure imminent — $(basename "$dev")" \
                            "${REALLOCATED} reallocated sector(s)" \
                            "Backup all data immediately. Replace drive." "$pfile"
                    elif [ "${PENDING:-0}" -ge 1 ] 2>/dev/null; then
                        add_problem "warning" "storage" "Unstable sectors — $(basename "$dev")" \
                            "${PENDING} pending sector(s) awaiting reallocation" \
                            "Run full SMART test. Back up data." "$pfile"
                    fi
                fi

                if echo "${SMART_HEALTH:-}" | grep -qiE "FAIL" 2>/dev/null; then
                    issue_count=$((issue_count + 1))
                    add_problem "critical" "storage" "SMART overall health FAILED — $(basename "$dev")" \
                        "SMART reports: $SMART_HEALTH" \
                        "Replace drive immediately. Back up all data now." "$pfile"
                fi
            fi
        fi

        # Lectura secuencial no destructiva (~5s, primeros 512MB)
        if cmd dd; then
            READ_SPEED_MBPS=$(dd if="$dev" of=/dev/null bs=4M count=128 2>&1 | \
                grep -oP '[0-9.]+ [MG]B/s' | head -1 | \
                awk '{if($2~/GB/) printf "%.0f",$1*1024; else printf "%.0f",$1}' 2>/dev/null || echo "")
        fi

        # Escritura secuencial — en la primera partición montada con escritura
        local WRITE_SPEED_MBPS=""
        if cmd dd; then
            local wpart wmp
            for wpart in "${dev}"1 "${dev}"p1 "${dev}"; do
                [ -b "$wpart" ] || continue
                wmp=$(awk -v p="$wpart" '$1==p{print $2}' /proc/mounts 2>/dev/null | head -1 || echo "")
                [ -z "$wmp" ] && continue
                [ -w "$wmp" ] || continue
                local wfile="${wmp}/.platine_wtest_$$"
                WRITE_SPEED_MBPS=$(dd if=/dev/zero of="$wfile" bs=4M count=128 \
                    conv=fdatasync 2>&1 | \
                    grep -oP '[0-9.]+ [MG]B/s' | head -1 | \
                    awk '{if($2~/GB/) printf "%.0f",$1*1024; else printf "%.0f",$1}' 2>/dev/null || echo "")
                rm -f "$wfile" 2>/dev/null || true
                break
            done
        fi

        # Estimación de vida útil restante
        local LIFE_PCT="" LIFE_LABEL=""
        if [ "$DTYPE" = "NVMe" ] && [ -n "${NVME_PCT_USED:-}" ]; then
            LIFE_PCT=$(( 100 - ${NVME_PCT_USED:-0} ))
            if   [ "$LIFE_PCT" -ge 80 ]; then LIFE_LABEL="excellent"
            elif [ "$LIFE_PCT" -ge 50 ]; then LIFE_LABEL="good"
            elif [ "$LIFE_PCT" -ge 20 ]; then LIFE_LABEL="fair"
            else LIFE_LABEL="critical"; fi
        elif [ "$DTYPE" = "SSD" ] && [ -n "${POWER_HOURS:-}" ]; then
            # SSD típico: ~10,000h de uso continuo → 40,000h totales encendido
            LIFE_PCT=$(awk -v h="${POWER_HOURS}" 'BEGIN{v=100-h*100/40000; if(v<0)v=0; printf "%.0f",v}' 2>/dev/null || echo "")
            [ -n "$LIFE_PCT" ] && {
                if   [ "$LIFE_PCT" -ge 80 ]; then LIFE_LABEL="excellent"
                elif [ "$LIFE_PCT" -ge 50 ]; then LIFE_LABEL="good"
                elif [ "$LIFE_PCT" -ge 20 ]; then LIFE_LABEL="fair"
                else LIFE_LABEL="critical"; fi
            }
        elif [ "$DTYPE" = "HDD" ] && [ -n "${POWER_HOURS:-}" ]; then
            # HDD típico: ~50,000h
            LIFE_PCT=$(awk -v h="${POWER_HOURS}" 'BEGIN{v=100-h*100/50000; if(v<0)v=0; printf "%.0f",v}' 2>/dev/null || echo "")
            [ -n "$LIFE_PCT" ] && {
                if   [ "$LIFE_PCT" -ge 80 ]; then LIFE_LABEL="excellent"
                elif [ "$LIFE_PCT" -ge 50 ]; then LIFE_LABEL="good"
                elif [ "$LIFE_PCT" -ge 20 ]; then LIFE_LABEL="fair"
                else LIFE_LABEL="critical"; fi
            }
            # Reallocated sectors anulan la estimación — disco falla pronto
            [ "${REALLOCATED:-0}" -ge 1 ] 2>/dev/null && { LIFE_PCT="0"; LIFE_LABEL="critical"; }
        fi

        drives_json="${drives_json}{\"device\":$(jstr "$dev"),\"type\":$(jstr "${DTYPE:-}"),\"model\":$(jstr "${MODEL:-}"),\"serial\":$(jstr "${SERIAL:-}"),\"size_gb\":$(jnum "${SIZE_GB:-}"),\"read_speed_mbps\":$(jnum "${READ_SPEED_MBPS:-}"),\"write_speed_mbps\":$(jnum "${WRITE_SPEED_MBPS:-}"),\"life_remaining_pct\":$(jnum "${LIFE_PCT:-}"),\"life_label\":$(jstr "${LIFE_LABEL:-}"),\"smart_health\":$(jstr "${SMART_HEALTH:-}"),\"temp_c\":$(jnum "${TEMP_C:-}"),\"power_hours\":$(jnum "${POWER_HOURS:-}"),\"reallocated_sectors\":$(jnum "${REALLOCATED:-0}"),\"pending_sectors\":$(jnum "${PENDING:-0}"),\"uncorrectable\":$(jnum "${UNCORRECTABLE:-0}"),\"nvme_percentage_used\":$(jnum "${NVME_PCT_USED:-}"),\"nvme_available_spare\":$(jnum "${NVME_SPARE:-}"),\"nvme_unsafe_shutdowns\":$(jnum "${NVME_UNSAFE_SHUT:-}"),\"nvme_power_cycles\":$(jnum "${NVME_POWER_CYCLES:-}"),\"smart_attrs\":[${attrs_json%,}]},"
    done

    local summ="${drive_count} drive(s) found"
    [ "$issue_count" -gt 0 ] && summ="${summ} ⚠ ${issue_count} ISSUE(S)"
    sum_set storage "$summ"

    printf '{"drives":[%s]}' "${drives_json%,}" > "$TMPD/json_storage.json"
    st_set storage done
}

# ── Scan: Battery ─────────────────────────────────────────────
scan_battery() {
    st_set battery running
    local pfile="$TMPD/probs_battery.ndjson"
    local bats_json="" bat_found=false
    local last_health="" last_cap="" last_swelling="false"

    for bat_path in /sys/class/power_supply/BAT* /sys/class/power_supply/battery; do
        [ -d "$bat_path" ] || continue
        bat_found=true

        local BNAME BSTATUS BTECH BMFR BCYCLES="" BVOLT="" BCAP="" BHEALTH=""
        local BFULL="" BDESIGN="" BSWELLING="false"

        BNAME=$(cat "$bat_path/name" 2>/dev/null || basename "$bat_path")
        BSTATUS=$(cat "$bat_path/status" 2>/dev/null || echo "Unknown")
        BTECH=$(cat "$bat_path/technology" 2>/dev/null || echo "")
        BMFR=$(cat "$bat_path/manufacturer" 2>/dev/null || echo "")
        BCYCLES=$(cat "$bat_path/cycle_count" 2>/dev/null || echo "")
        BCAP=$(cat "$bat_path/capacity" 2>/dev/null || echo "")
        BVOLT=$(cat "$bat_path/voltage_now" 2>/dev/null | \
                awk '{printf "%.3f",$1/1000000}' 2>/dev/null || echo "")

        if [ -f "$bat_path/energy_full" ]; then
            BFULL=$(awk '{printf "%.0f",$1/1000}' "$bat_path/energy_full" 2>/dev/null || echo "")
            BDESIGN=$(awk '{printf "%.0f",$1/1000}' "$bat_path/energy_full_design" 2>/dev/null || echo "")
        elif [ -f "$bat_path/charge_full" ]; then
            BFULL=$(awk '{printf "%.0f",$1/1000}' "$bat_path/charge_full" 2>/dev/null || echo "")
            BDESIGN=$(awk '{printf "%.0f",$1/1000}' "$bat_path/charge_full_design" 2>/dev/null || echo "")
        fi

        if [ -n "${BFULL:-}" ] && [ -n "${BDESIGN:-}" ] && [ "${BDESIGN:-0}" -gt 0 ] 2>/dev/null; then
            BHEALTH=$(awk -v f="${BFULL}" -v d="${BDESIGN}" \
                'BEGIN{printf "%.0f",f*100/d}' 2>/dev/null || echo "")
        fi

        # Swelling: reported full > 105% of design
        if [ -n "${BFULL:-}" ] && [ -n "${BDESIGN:-}" ]; then
            if awk -v f="${BFULL}" -v d="${BDESIGN}" 'BEGIN{exit !(f+0 > d*1.05)}' 2>/dev/null; then
                BSWELLING="true"
                add_problem "critical" "battery" "Battery swelling risk detected" \
                    "Reported capacity (${BFULL} mWh) exceeds design (${BDESIGN} mWh)" \
                    "Power off immediately. Do not charge. Replace battery — fire risk." "$pfile"
            fi
        fi

        if [ -n "${BHEALTH:-}" ] && [ "${BHEALTH:-100}" -lt 50 ] 2>/dev/null; then
            add_problem "warning" "battery" "Battery health critically low" \
                "Health at ${BHEALTH}% (threshold: 50%)" \
                "Replace battery for reliable operation." "$pfile"
        fi

        if [ -n "${BCYCLES:-}" ] && [ "${BCYCLES:-0}" -gt 1000 ] 2>/dev/null; then
            add_problem "warning" "battery" "Battery cycle count very high" \
                "Cycle count: ${BCYCLES} (typical max: 500-1000)" \
                "Consider replacing battery." "$pfile"
        fi

        last_health="${BHEALTH:-}"; last_cap="${BCAP:-}"; last_swelling="$BSWELLING"

        # Estimación de vida útil restante
        local BLIFE_PCT="" BLIFE_LABEL=""
        if [ -n "${BHEALTH:-}" ]; then
            BLIFE_PCT="$BHEALTH"
            if   [ "${BHEALTH:-0}" -ge 80 ]; then BLIFE_LABEL="excellent"
            elif [ "${BHEALTH:-0}" -ge 60 ]; then BLIFE_LABEL="good"
            elif [ "${BHEALTH:-0}" -ge 40 ]; then BLIFE_LABEL="fair"
            else BLIFE_LABEL="critical"; fi
            [ "$BSWELLING" = "true" ] && BLIFE_LABEL="critical"
        fi

        bats_json="${bats_json}{\"name\":$(jstr "${BNAME:-}"),\"status\":$(jstr "${BSTATUS:-}"),\"technology\":$(jstr "${BTECH:-}"),\"manufacturer\":$(jstr "${BMFR:-}"),\"charge_pct\":$(jnum "${BCAP:-}"),\"health_pct\":$(jnum "${BHEALTH:-}"),\"life_remaining_pct\":$(jnum "${BLIFE_PCT:-}"),\"life_label\":$(jstr "${BLIFE_LABEL:-}"),\"design_mwh\":$(jnum "${BDESIGN:-}"),\"full_mwh\":$(jnum "${BFULL:-}"),\"voltage_v\":$(jnum "${BVOLT:-}"),\"cycle_count\":$(jnum "${BCYCLES:-}"),\"swelling_risk\":$(jbool "${BSWELLING}")},"
    done

    local summ
    if [ "$bat_found" = "true" ]; then
        summ="Battery found"
        [ -n "${last_cap:-}" ]    && summ="${summ} · ${last_cap}%"
        [ -n "${last_health:-}" ] && summ="${summ} · health ${last_health}%"
        [ "${last_swelling:-false}" = "true" ] && summ="${summ} ⚠ SWELLING"
    else
        summ="No battery (desktop)"
    fi
    sum_set battery "$summ"

    printf '{"batteries":[%s]}' "${bats_json%,}" > "$TMPD/json_battery.json"
    st_set battery done
}

# ── Scan: GPU ─────────────────────────────────────────────────
scan_gpu() {
    st_set gpu running
    local gpus_json="" gpu_count=0

    # nvidia-smi data (disponible si el driver propietario está cargado)
    local NVIDIA_SMI_OUT=""
    cmd nvidia-smi && \
        NVIDIA_SMI_OUT=$(nvidia-smi \
            --query-gpu=index,name,temperature.gpu,memory.total,memory.used,power.draw,driver_version \
            --format=csv,noheader,nounits 2>/dev/null || echo "")

    if cmd lspci; then
        while IFS= read -r line; do
            local GSLOT GMODEL GDRIVER="" GREVISION="" GFW="" GVRAM="" GVRAM_USED="" GTEMP="" GPOWER_W=""
            GSLOT=$(echo "$line" | awk '{print $1}')
            GMODEL=$(echo "$line" | cut -d: -f3- | xargs 2>/dev/null || echo "Unknown GPU")
            gpu_count=$((gpu_count + 1))
            local gidx=$((gpu_count - 1))

            GDRIVER=$(lspci -k -s "$GSLOT" 2>/dev/null | grep 'Kernel driver in use:' | \
                      cut -d: -f2 | xargs 2>/dev/null || echo "")
            GREVISION=$(lspci -v -s "$GSLOT" 2>/dev/null | grep -i 'Revision:' | \
                        awk '{print $NF}' | head -1 || echo "")
            GFW=$(cat "/sys/class/drm/card${gidx}/device/fw_version" 2>/dev/null || echo "")

            local vram_file="/sys/class/drm/card${gidx}/device/mem_info_vram_total"
            [ -f "$vram_file" ] && GVRAM=$(awk '{printf "%.0f",$1/1024/1024}' "$vram_file" 2>/dev/null || echo "")

            # nvidia-smi override (más preciso para Nvidia)
            if [ -n "${NVIDIA_SMI_OUT:-}" ] && echo "$GMODEL" | grep -qiE "nvidia|geforce|quadro|tesla"; then
                local nv_row
                nv_row=$(echo "$NVIDIA_SMI_OUT" | awk -v idx="$gidx" -F',' 'NR==idx+1{print}' | head -1)
                if [ -n "${nv_row:-}" ]; then
                    GTEMP=$(echo "$nv_row"     | awk -F',' '{gsub(/ /,"",$3); print $3}' || echo "")
                    GVRAM=$(echo "$nv_row"     | awk -F',' '{gsub(/ /,"",$4); print $4}' || echo "")
                    GVRAM_USED=$(echo "$nv_row"| awk -F',' '{gsub(/ /,"",$5); print $5}' || echo "")
                    GPOWER_W=$(echo "$nv_row"  | awk -F',' '{gsub(/ /,"",$6); print $6}' || echo "")
                fi
            fi

            # hwmon fallback para temp (AMD/Intel)
            if [ -z "${GTEMP:-}" ]; then
                local hwmon hname
                for hwmon in /sys/class/hwmon/hwmon*/; do
                    [ -d "$hwmon" ] || continue
                    hname=$(cat "${hwmon}name" 2>/dev/null || echo "")
                    echo "$hname" | grep -qiE "amdgpu|radeon|nouveau|nvidia" || continue
                    local tf="${hwmon}temp1_input"
                    [ -f "$tf" ] && GTEMP=$(awk '{printf "%.0f",$1/1000}' "$tf" 2>/dev/null || echo "")
                    break
                done
            fi

            gpus_json="${gpus_json}{\"slot\":$(jstr "${GSLOT:-}"),\"model\":$(jstr "${GMODEL:-}"),\"driver\":$(jstr "${GDRIVER:-}"),\"revision\":$(jstr "${GREVISION:-}"),\"firmware\":$(jstr "${GFW:-}"),\"vram_mb\":$(jnum "${GVRAM:-}"),\"vram_used_mb\":$(jnum "${GVRAM_USED:-}"),\"temp_c\":$(jnum "${GTEMP:-}"),\"power_w\":$(jnum "${GPOWER_W:-}")},"
        done < <(lspci 2>/dev/null | grep -iE 'VGA compatible|3D controller|Display controller' || true)
    fi

    sum_set gpu "${gpu_count} GPU(s)"
    printf '{"gpus":[%s]}' "${gpus_json%,}" > "$TMPD/json_gpu.json"
    st_set gpu done
}

# ── Scan: Network ─────────────────────────────────────────────
scan_network() {
    st_set network running
    local ifaces_json="" iface_count=0

    for ipath in /sys/class/net/*/; do
        local IFACE; IFACE=$(basename "$ipath")
        echo "$IFACE" | grep -qE '^(lo|dummy|virbr|docker|veth|br-|bond|sit|tun|tap)' && continue
        iface_count=$((iface_count + 1))

        local ITYPE="" IMAC="" ISPEED="" ISTATUS="" IS_WLAN="false"
        local ICHAN="" IFREQ="" ISIG="" ISSID="" ICARRIER="0" IDUPLEX="" IDRIVER=""

        IMAC=$(cat "${ipath}address" 2>/dev/null || echo "")
        ISTATUS=$(cat "${ipath}operstate" 2>/dev/null || echo "unknown")
        ICARRIER=$(cat "${ipath}carrier" 2>/dev/null || echo "0")
        ISPEED=$(cat "${ipath}speed" 2>/dev/null || echo "")
        IDUPLEX=$(cat "${ipath}duplex" 2>/dev/null || echo "")
        IDRIVER=$(readlink -f "${ipath}device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")

        if [ -d "${ipath}wireless" ] || echo "$IFACE" | grep -qE '^(wl|wlan|wlp|ath|ra[0-9])'; then
            IS_WLAN="true"; ITYPE="WiFi"
            if cmd iw; then
                local iw_out
                iw_out=$(iw dev "$IFACE" link 2>/dev/null || iw dev "$IFACE" info 2>/dev/null || echo "")
                ICHAN=$(echo "$iw_out"  | grep -oP '(?<=channel )[0-9]+' | head -1 || echo "")
                IFREQ=$(echo "$iw_out"  | grep -oP '[0-9]+\.[0-9]+ GHz' | head -1 || echo "")
                ISIG=$(echo "$iw_out"   | grep -oP '(?<=signal: )-?[0-9]+' | head -1 || echo "")
                ISSID=$(echo "$iw_out"  | grep -oP '(?<=SSID: ).+' | head -1 | xargs 2>/dev/null || echo "")
            fi
            if cmd iwconfig && [ -z "${ISIG:-}" ]; then
                local iwc_out
                iwc_out=$(iwconfig "$IFACE" 2>/dev/null || echo "")
                ISIG=$(echo "$iwc_out" | grep -oP '(?<=Signal level=)-?[0-9]+' | head -1 || echo "")
                [ -z "${ISSID:-}" ] && ISSID=$(echo "$iwc_out" | grep -oP '(?<=ESSID:")[^"]+' | head -1 || echo "")
            fi
        elif echo "$IFACE" | grep -qE '^usb'; then
            ITYPE="USB-Ethernet"
        elif echo "$IFACE" | grep -qE '^(eth|enp|ens|eno|em)'; then
            ITYPE="Ethernet"
        else
            ITYPE="Unknown"
        fi

        ifaces_json="${ifaces_json}{\"interface\":$(jstr "${IFACE:-}"),\"type\":$(jstr "${ITYPE:-}"),\"mac\":$(jstr "${IMAC:-}"),\"status\":$(jstr "${ISTATUS:-}"),\"carrier\":$(jnum "${ICARRIER:-0}"),\"speed_mbps\":$(jnum "${ISPEED:-}"),\"duplex\":$(jstr "${IDUPLEX:-}"),\"driver\":$(jstr "${IDRIVER:-}"),\"wifi_ssid\":$(jstr "${ISSID:-}"),\"wifi_channel\":$(jnum "${ICHAN:-}"),\"wifi_freq_ghz\":$(jstr "${IFREQ:-}"),\"wifi_signal_dbm\":$(jnum "${ISIG:-}")},"
    done

    sum_set network "${iface_count} interface(s)"
    printf '{"interfaces":[%s]}' "${ifaces_json%,}" > "$TMPD/json_network.json"
    st_set network done
}

# ── Scan: Thermals ────────────────────────────────────────────
scan_thermals() {
    st_set thermals running
    local pfile="$TMPD/probs_thermals.ndjson"
    local sensors_json="" fans_json="" fan_stopped=0 fan_total=0

    for hwmon in /sys/class/hwmon/hwmon*/; do
        [ -d "$hwmon" ] || continue
        local HNAME; HNAME=$(cat "${hwmon}name" 2>/dev/null || echo "unknown")

        for tf in "${hwmon}"temp*_input; do
            [ -f "$tf" ] || continue
            local lbl tc crit_c
            lbl=$(cat "${tf/_input/_label}" 2>/dev/null || echo "$HNAME")
            tc=$(awk '{printf "%.1f",$1/1000}' "$tf" 2>/dev/null || echo "")
            crit_c=$(awk '{printf "%.1f",$1/1000}' "${tf/_input/_crit}" 2>/dev/null || echo "")
            [ -z "$tc" ] && continue
            sensors_json="${sensors_json}{\"hwmon\":$(jstr "${HNAME:-}"),\"label\":$(jstr "${lbl:-}"),\"temp_c\":$(jnum "${tc:-}"),\"crit_c\":$(jnum "${crit_c:-}")},"
        done

        for ff in "${hwmon}"fan*_input; do
            [ -f "$ff" ] || continue
            fan_total=$((fan_total + 1))
            local flbl frpm fmin
            flbl=$(cat "${ff/_input/_label}" 2>/dev/null || echo "fan")
            frpm=$(cat "$ff" 2>/dev/null || echo "")
            fmin=$(cat "${ff/_input/_min}" 2>/dev/null || echo "")
            fans_json="${fans_json}{\"hwmon\":$(jstr "${HNAME:-}"),\"label\":$(jstr "${flbl:-}"),\"rpm\":$(jnum "${frpm:-}"),\"min_rpm\":$(jnum "${fmin:-}")},"

            if [ "${frpm:-1}" = "0" ] || \
               { [ -n "${frpm:-}" ] && [ "${frpm}" -eq 0 ] 2>/dev/null; }; then
                fan_stopped=$((fan_stopped + 1))
                add_problem "critical" "thermals" "Fan not spinning — ${HNAME}/${flbl}" \
                    "Fan RPM reads 0 while system is running" \
                    "Check fan connector, clear obstructions, or replace fan." "$pfile"
            fi
        done
    done

    local summ
    if [ "$fan_total" -eq 0 ]; then summ="No fans detected"
    elif [ "$fan_stopped" -gt 0 ]; then summ="${fan_stopped}/${fan_total} fan(s) STOPPED ⚠"
    else summ="All ${fan_total} fan(s) OK"; fi
    sum_set thermals "$summ"

    cat > "$TMPD/json_thermals.json" <<JSON
{
  "sensors": [${sensors_json%,}],
  "fans": [${fans_json%,}],
  "fan_count": $(jnum "$fan_total"),
  "fans_stopped": $(jnum "$fan_stopped")
}
JSON
    st_set thermals done
}

# ── Scan: Audio ───────────────────────────────────────────────
scan_audio() {
    st_set audio running
    local cards_json="" card_count=0

    for card in /proc/asound/card*/; do
        [ -d "$card" ] || continue
        card_count=$((card_count + 1))
        local cname cinfo
        cname=$(cat "${card}id" 2>/dev/null | xargs 2>/dev/null || basename "$card")
        cinfo=$(cat "${card}codec#0" 2>/dev/null | grep -m1 'Codec:' | cut -d: -f2 | xargs 2>/dev/null || echo "")
        cards_json="${cards_json}{\"card\":$(jstr "$(basename "$card")"),\"name\":$(jstr "${cname:-}"),\"codec\":$(jstr "${cinfo:-}")},"
    done

    if [ "$card_count" -eq 0 ] && cmd lspci; then
        while IFS= read -r line; do
            local aname; aname=$(echo "$line" | cut -d: -f3- | xargs 2>/dev/null || echo "")
            card_count=$((card_count + 1))
            cards_json="${cards_json}{\"card\":\"pci\",\"name\":$(jstr "${aname:-}"),\"codec\":\"\"},"
        done < <(lspci 2>/dev/null | grep -iE 'Audio|Sound|Multimedia' || true)
    fi

    sum_set audio "${card_count} audio card(s)"
    printf '{"cards":[%s]}' "${cards_json%,}" > "$TMPD/json_audio.json"
    st_set audio done
}

# ── Scan: USB ─────────────────────────────────────────────────
scan_usb() {
    st_set usb running
    local devs_json="" dev_count=0

    if cmd lsusb; then
        while IFS= read -r line; do
            [ -z "$line" ] && continue
            local vid pid name
            vid=$(echo "$line"  | grep -oP 'ID \K[0-9a-f]{4}' | head -1 || echo "")
            pid=$(echo "$line"  | grep -oP 'ID [0-9a-f]{4}:\K[0-9a-f]{4}' | head -1 || echo "")
            name=$(echo "$line" | cut -d' ' -f7- | xargs 2>/dev/null || echo "")
            dev_count=$((dev_count + 1))
            devs_json="${devs_json}{\"vid\":$(jstr "${vid:-}"),\"pid\":$(jstr "${pid:-}"),\"name\":$(jstr "${name:-}")},"
        done < <(lsusb 2>/dev/null | grep -v 'Linux Foundation' || true)
    fi

    sum_set usb "${dev_count} USB device(s)"
    printf '{"devices":[%s]}' "${devs_json%,}" > "$TMPD/json_usb.json"
    st_set usb done
}

# ── Scan: OS ──────────────────────────────────────────────────
scan_os() {
    st_set os running
    local OS_NAME="" KERNEL="" UPTIME_S="" BIOS_VER="" BIOS_DATE=""

    OS_NAME=$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-}" || \
              cat /etc/alpine-release 2>/dev/null | head -1 || echo "Unknown")
    KERNEL=$(uname -r 2>/dev/null || echo "")
    UPTIME_S=$(awk '{printf "%.0f",$1}' /proc/uptime 2>/dev/null || echo "")

    if cmd dmidecode; then
        BIOS_VER=$(dmidecode -s bios-version      2>/dev/null | head -1 | xargs 2>/dev/null || echo "")
        BIOS_DATE=$(dmidecode -s bios-release-date 2>/dev/null | head -1 | xargs 2>/dev/null || echo "")
    fi
    [ -z "${BIOS_VER:-}" ]  && BIOS_VER=$(cat /sys/class/dmi/id/bios_version 2>/dev/null | xargs 2>/dev/null || echo "")
    [ -z "${BIOS_DATE:-}" ] && BIOS_DATE=$(cat /sys/class/dmi/id/bios_date   2>/dev/null | xargs 2>/dev/null || echo "")

    sum_set os "${OS_NAME:-Unknown} · ${KERNEL:-?}"
    cat > "$TMPD/json_os.json" <<JSON
{
  "name": $(jstr "${OS_NAME:-}"),
  "kernel": $(jstr "${KERNEL:-}"),
  "uptime_s": $(jnum "${UPTIME_S:-}"),
  "bios_version": $(jstr "${BIOS_VER:-}"),
  "bios_date": $(jstr "${BIOS_DATE:-}")
}
JSON
    st_set os done
}

# ── Scan: Security ────────────────────────────────────────────
scan_security() {
    st_set security running
    local SB_STATUS="" TPM_VER="none" IOMMU_ENABLED="false"

    local sb_efi="/sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c"
    if [ -f "$sb_efi" ]; then
        local sb_val
        sb_val=$(od -An -tu1 "$sb_efi" 2>/dev/null | awk '{print $NF}' || echo "0")
        [ "${sb_val:-0}" = "1" ] && SB_STATUS="enabled" || SB_STATUS="disabled"
    elif [ -d /sys/firmware/efi ]; then
        SB_STATUS="disabled"
    else
        SB_STATUS="legacy_bios"
    fi

    if [ -d /sys/class/tpm/tpm0 ]; then
        local tpm_maj
        tpm_maj=$(cat /sys/class/tpm/tpm0/tpm_version_major 2>/dev/null || echo "1")
        TPM_VER="TPM ${tpm_maj}.x"
    fi

    dmesg 2>/dev/null | grep -qiE 'DMAR|AMD-Vi|IOMMU' 2>/dev/null && IOMMU_ENABLED="true" || true

    sum_set security "SecureBoot:${SB_STATUS:-?} TPM:${TPM_VER}"
    cat > "$TMPD/json_security.json" <<JSON
{
  "secure_boot": $(jstr "${SB_STATUS:-}"),
  "tpm": $(jstr "${TPM_VER:-none}"),
  "iommu": $(jbool "${IOMMU_ENABLED}")
}
JSON
    st_set security done
}

# ── Scan: iOS device via libimobiledevice ────────────────────
scan_ios() {
    st_set ios running
    local pfile="$TMPD/probs_ios.ndjson"

    if ! cmd idevice_id; then
        sum_set ios "libimobiledevice not available"
        printf 'null' > "$TMPD/json_ios.json"
        st_set ios done
        return
    fi

    # Intentar emparejar si no está (requiere que el usuario confíe en el PC en el iPhone)
    idevicepair pair 2>/dev/null || true
    sleep 1

    local UDID
    UDID=$(idevice_id -l 2>/dev/null | head -1 | tr -d '\r\n' || echo "")

    if [ -z "${UDID:-}" ]; then
        sum_set ios "No iOS device"
        printf '{"detected":false}' > "$TMPD/json_ios.json"
        st_set ios done
        return
    fi

    local INFO_OUT
    INFO_OUT=$(ideviceinfo -u "$UDID" 2>/dev/null || echo "")

    get_prop() { echo "$INFO_OUT" | grep "^${1}:" | cut -d: -f2- | xargs 2>/dev/null || echo ""; }

    local INAME IMODEL IOS_VER BUILD SERIAL IMEI STORAGE_TOTAL STORAGE_FREE
    INAME=$(        get_prop "DeviceName")
    IMODEL=$(       get_prop "ProductType")       # ej: iPhone15,3
    IOS_VER=$(      get_prop "ProductVersion")    # ej: 17.4.1
    BUILD=$(        get_prop "BuildVersion")
    SERIAL=$(       get_prop "SerialNumber")
    IMEI=$(         get_prop "InternationalMobileEquipmentIdentity")
    STORAGE_TOTAL=$(get_prop "TotalDiskCapacity"  | awk '{printf "%.1f",$1/1024/1024/1024}' 2>/dev/null || echo "")
    STORAGE_FREE=$( get_prop "TotalDataAvailable" | awk '{printf "%.1f",$1/1024/1024/1024}' 2>/dev/null || echo "")

    # Batería via diagnostics
    local BAT_INFO BAT_LEVEL="" BAT_HEALTH="" BAT_CYCLES="" BAT_DESIGN_CAP="" BAT_FULL_CAP=""
    BAT_INFO=$(idevicediagnostics ioreg --class IOPMPowerSource 2>/dev/null | \
               grep -E 'ExternalCharge|CurrentCapacity|DesignCapacity|CycleCount|BatteryHealth' || echo "")
    BAT_LEVEL=$(  echo "$BAT_INFO" | grep -i 'CurrentCapacity' | grep -oP '[0-9]+' | head -1 || echo "")
    BAT_CYCLES=$( echo "$BAT_INFO" | grep -i 'CycleCount'      | grep -oP '[0-9]+' | head -1 || echo "")
    BAT_DESIGN_CAP=$(echo "$BAT_INFO" | grep -i 'DesignCapacity' | grep -oP '[0-9]+' | head -1 || echo "")
    BAT_FULL_CAP=$(  echo "$BAT_INFO" | grep -i 'MaxCapacity'    | grep -oP '[0-9]+' | head -1 || echo "")

    local BAT_HEALTH_PCT=""
    if [ -n "${BAT_FULL_CAP:-}" ] && [ -n "${BAT_DESIGN_CAP:-}" ] && [ "${BAT_DESIGN_CAP:-0}" -gt 0 ] 2>/dev/null; then
        BAT_HEALTH_PCT=$(awk -v f="${BAT_FULL_CAP}" -v d="${BAT_DESIGN_CAP}" \
            'BEGIN{printf "%.0f",f*100/d}' 2>/dev/null || echo "")
    fi

    # iOS version age warning (>3 versiones principales atrás = inseguro)
    if [ -n "${IOS_VER:-}" ]; then
        local ios_major
        ios_major=$(echo "$IOS_VER" | cut -d. -f1)
        local current_ios=18  # actualizar según año
        if [ -n "$ios_major" ] && [ $(( current_ios - ios_major )) -ge 2 ] 2>/dev/null; then
            add_problem "warning" "ios" "iOS version very outdated" \
                "Running iOS ${IOS_VER} (current: ~${current_ios}.x)" \
                "Update iOS for security patches and app compatibility." "$pfile"
        fi
    fi

    # Battery health warning
    if [ -n "${BAT_HEALTH_PCT:-}" ] && [ "${BAT_HEALTH_PCT:-100}" -lt 80 ] 2>/dev/null; then
        add_problem "warning" "ios" "iPhone battery health below Apple threshold" \
            "Battery health: ${BAT_HEALTH_PCT}% (Apple recommends replacement at <80%)" \
            "Replace battery at an Apple authorized service provider." "$pfile"
    fi

    sum_set ios "${INAME:-iPhone} · iOS ${IOS_VER:-?} · Bat:${BAT_LEVEL:-?}%"

    cat > "$TMPD/json_ios.json" <<JSON
{
  "detected": true,
  "udid": $(jstr "${UDID:-}"),
  "name": $(jstr "${INAME:-}"),
  "model": $(jstr "${IMODEL:-}"),
  "ios_version": $(jstr "${IOS_VER:-}"),
  "build_version": $(jstr "${BUILD:-}"),
  "serial": $(jstr "${SERIAL:-}"),
  "imei": $(jstr "${IMEI:-}"),
  "battery": {
    "level_pct": $(jnum "${BAT_LEVEL:-}"),
    "health_pct": $(jnum "${BAT_HEALTH_PCT:-}"),
    "cycle_count": $(jnum "${BAT_CYCLES:-}"),
    "design_cap_mah": $(jnum "${BAT_DESIGN_CAP:-}"),
    "full_cap_mah": $(jnum "${BAT_FULL_CAP:-}")
  },
  "storage": {
    "total_gb": $(jnum "${STORAGE_TOTAL:-}"),
    "available_gb": $(jnum "${STORAGE_FREE:-}")
  }
}
JSON
    st_set ios done
}

# ── Scan: Android phone via ADB ──────────────────────────────
scan_android() {
    st_set android running
    local pfile="$TMPD/probs_android.ndjson"

    if ! cmd adb; then
        sum_set android "adb not available"
        printf 'null' > "$TMPD/json_android.json"
        st_set android done
        return
    fi

    adb start-server 2>/dev/null || true
    sleep 1

    local DEVICE_SERIAL
    DEVICE_SERIAL=$(adb devices 2>/dev/null | grep -v "^List\|^$\|unauthorized\|offline" \
        | awk 'NR==1{print $1}' || echo "")

    if [ -z "${DEVICE_SERIAL:-}" ]; then
        sum_set android "No device connected"
        printf '{"detected":false}' > "$TMPD/json_android.json"
        st_set android done
        return
    fi

    local ADB_SH="adb -s ${DEVICE_SERIAL} shell"

    local BRAND MODEL ANDROID_VER SECURITY_PATCH HARDWARE ARCH FINGERPRINT
    BRAND=$(           $ADB_SH getprop ro.product.brand         2>/dev/null | tr -d '\r\n' || echo "")
    MODEL=$(           $ADB_SH getprop ro.product.model         2>/dev/null | tr -d '\r\n' || echo "")
    ANDROID_VER=$(     $ADB_SH getprop ro.build.version.release 2>/dev/null | tr -d '\r\n' || echo "")
    SECURITY_PATCH=$(  $ADB_SH getprop ro.build.version.security_patch 2>/dev/null | tr -d '\r\n' || echo "")
    HARDWARE=$(        $ADB_SH getprop ro.hardware              2>/dev/null | tr -d '\r\n' || echo "")
    ARCH=$(            $ADB_SH getprop ro.product.cpu.abi       2>/dev/null | tr -d '\r\n' || echo "")

    # Battery
    local BAT_LEVEL="" BAT_HEALTH_CODE="" BAT_HEALTH_STR="" BAT_TEMP_C="" BAT_VOLTAGE_V=""
    local bat_dump
    bat_dump=$($ADB_SH dumpsys battery 2>/dev/null || echo "")
    BAT_LEVEL=$(       echo "$bat_dump" | grep -oP '(?<=level: )[0-9]+'       | head -1 || echo "")
    BAT_HEALTH_CODE=$( echo "$bat_dump" | grep -oP '(?<=health: )[0-9]+'      | head -1 || echo "")
    local bat_temp_raw
    bat_temp_raw=$(    echo "$bat_dump" | grep -oP '(?<=temperature: )[0-9]+' | head -1 || echo "")
    [ -n "$bat_temp_raw" ] && BAT_TEMP_C=$(awk -v t="$bat_temp_raw" 'BEGIN{printf "%.1f",t/10}')
    local bat_volt_raw
    bat_volt_raw=$(    echo "$bat_dump" | grep -oP '(?<=voltage: )[0-9]+'     | head -1 || echo "")
    [ -n "$bat_volt_raw" ] && BAT_VOLTAGE_V=$(awk -v v="$bat_volt_raw" 'BEGIN{printf "%.3f",v/1000}')

    case "${BAT_HEALTH_CODE:-2}" in
        2) BAT_HEALTH_STR="good" ;;
        3) BAT_HEALTH_STR="overheat"
           add_problem "critical" "android" "Phone battery overheating" \
               "Android reports battery health: Overheat" "Replace battery." "$pfile" ;;
        4) BAT_HEALTH_STR="dead"
           add_problem "critical" "android" "Phone battery dead" \
               "Android reports battery health: Dead" "Replace battery immediately." "$pfile" ;;
        5) BAT_HEALTH_STR="overvoltage"
           add_problem "warning" "android" "Phone battery overvoltage" \
               "Android reports battery health: OverVoltage" \
               "Check charger, replace battery." "$pfile" ;;
        *) BAT_HEALTH_STR="unknown" ;;
    esac

    # Low battery warning
    if [ -n "${BAT_LEVEL:-}" ] && [ "${BAT_LEVEL:-100}" -lt 20 ] 2>/dev/null; then
        add_problem "warning" "android" "Phone battery critically low" \
            "Battery level: ${BAT_LEVEL}%" "Charge device." "$pfile"
    fi

    # RAM
    local PHONE_RAM_GB="" PHONE_RAM_AVAIL_GB=""
    local mem_info
    mem_info=$($ADB_SH cat /proc/meminfo 2>/dev/null || echo "")
    PHONE_RAM_GB=$(    echo "$mem_info" | awk '/^MemTotal:/{printf "%.1f",$2/1048576}'    2>/dev/null || echo "")
    PHONE_RAM_AVAIL_GB=$(echo "$mem_info" | awk '/^MemAvailable:/{printf "%.1f",$2/1048576}' 2>/dev/null || echo "")

    # Internal storage (/data partition)
    local PHONE_STORE_GB="" PHONE_STORE_AVAIL_GB=""
    local df_line
    df_line=$($ADB_SH df /data 2>/dev/null | tail -1 || echo "")
    if [ -n "$df_line" ]; then
        PHONE_STORE_GB=$(     echo "$df_line" | awk '{printf "%.1f",$2/1048576}' 2>/dev/null || echo "")
        PHONE_STORE_AVAIL_GB=$(echo "$df_line" | awk '{printf "%.1f",$4/1048576}' 2>/dev/null || echo "")
    fi

    # Security patch age
    if [ -n "${SECURITY_PATCH:-}" ]; then
        local patch_year
        patch_year=$(echo "$SECURITY_PATCH" | grep -oP '^\d{4}' || echo "")
        if [ -n "${patch_year:-}" ]; then
            local patch_age=$(( $(date +%Y) - patch_year ))
            if [ "${patch_age:-0}" -ge 2 ]; then
                add_problem "warning" "android" \
                    "Android security patch outdated (${patch_age} years)" \
                    "Last patch: ${SECURITY_PATCH}" \
                    "Update Android or replace device." "$pfile"
            fi
        fi
    fi

    sum_set android "${BRAND:-?} ${MODEL:-?} · Android ${ANDROID_VER:-?} · Bat:${BAT_LEVEL:-?}%"

    cat > "$TMPD/json_android.json" <<JSON
{
  "detected": true,
  "device_serial": $(jstr "${DEVICE_SERIAL:-}"),
  "brand": $(jstr "${BRAND:-}"),
  "model": $(jstr "${MODEL:-}"),
  "android_version": $(jstr "${ANDROID_VER:-}"),
  "security_patch": $(jstr "${SECURITY_PATCH:-}"),
  "hardware": $(jstr "${HARDWARE:-}"),
  "cpu_abi": $(jstr "${ARCH:-}"),
  "battery": {
    "level_pct": $(jnum "${BAT_LEVEL:-}"),
    "health": $(jstr "${BAT_HEALTH_STR:-unknown}"),
    "temp_c": $(jnum "${BAT_TEMP_C:-}"),
    "voltage_v": $(jnum "${BAT_VOLTAGE_V:-}")
  },
  "ram": {
    "total_gb": $(jnum "${PHONE_RAM_GB:-}"),
    "available_gb": $(jnum "${PHONE_RAM_AVAIL_GB:-}")
  },
  "storage": {
    "total_gb": $(jnum "${PHONE_STORE_GB:-}"),
    "available_gb": $(jnum "${PHONE_STORE_AVAIL_GB:-}")
  }
}
JSON
    st_set android done
}

# ── Scan: Network speed test ─────────────────────────────────
scan_netspeed() {
    st_set netspeed running
    local DL_MBPS="" UL_MBPS="" LATENCY_MS="" PKT_LOSS=""

    # Latency + packet loss
    if cmd ping; then
        local ping_out
        ping_out=$(ping -c 5 -q 8.8.8.8 2>/dev/null || echo "")
        LATENCY_MS=$(echo "$ping_out" | grep -oP 'rtt.*= [0-9.]+/\K[0-9.]+' | head -1 || echo "")
        [ -z "$LATENCY_MS" ] && \
            LATENCY_MS=$(echo "$ping_out" | grep -oP 'avg.*= [0-9.]+/\K[0-9.]+' | head -1 || echo "")
        PKT_LOSS=$(echo "$ping_out" | grep -oP '[0-9]+(?=% packet loss)' | head -1 || echo "0")
    fi

    if cmd curl; then
        # Download: 5 MB from Cloudflare
        DL_MBPS=$(curl -o /dev/null -s -w '%{speed_download}' \
            --connect-timeout 5 --max-time 20 \
            'https://speed.cloudflare.com/__down?bytes=5000000' 2>/dev/null | \
            awk '{printf "%.1f",$1/125000}' 2>/dev/null || echo "")

        # Upload: 2 MB to Cloudflare
        UL_MBPS=$(dd if=/dev/urandom bs=1M count=2 2>/dev/null | \
            curl -o /dev/null -s -w '%{speed_upload}' \
            --connect-timeout 5 --max-time 20 \
            -X POST 'https://speed.cloudflare.com/__up' \
            -H 'Content-Type: application/octet-stream' \
            --data-binary @- 2>/dev/null | \
            awk '{printf "%.1f",$1/125000}' 2>/dev/null || echo "")
    fi

    # Warn on high latency or packet loss
    local pfile="$TMPD/probs_netspeed.ndjson"
    if [ -n "${PKT_LOSS:-}" ] && [ "${PKT_LOSS:-0}" -gt 0 ] 2>/dev/null; then
        add_problem "warning" "network" "Packet loss detected" \
            "${PKT_LOSS}% packet loss to 8.8.8.8" \
            "Check network cable, router, or ISP connection." "$pfile"
    fi
    if [ -n "${LATENCY_MS:-}" ] && awk -v l="${LATENCY_MS}" 'BEGIN{exit !(l+0>150)}' 2>/dev/null; then
        add_problem "warning" "network" "High network latency" \
            "Ping to 8.8.8.8: ${LATENCY_MS}ms (normal <50ms)" \
            "Check connection quality. May indicate ISP issue." "$pfile"
    fi

    sum_set netspeed "↓${DL_MBPS:-?}Mbps ↑${UL_MBPS:-?}Mbps Ping:${LATENCY_MS:-?}ms"

    cat > "$TMPD/json_netspeed.json" <<JSON
{
  "ping_ms": $(jnum "${LATENCY_MS:-}"),
  "packet_loss_pct": $(jnum "${PKT_LOSS:-0}"),
  "download_mbps": $(jnum "${DL_MBPS:-}"),
  "upload_mbps": $(jnum "${UL_MBPS:-}")
}
JSON
    st_set netspeed done
}

# ── Form factor derivation ────────────────────────────────────
get_form_factor() {
    local chassis
    chassis=$(cat "$TMPD/machine_chassis" 2>/dev/null || echo "")
    case "$chassis" in
        [Nn]ote*|[Ll]apt*|[Ss]ub*|[Tt]ablet|notebook|laptop|9|10|14|30|31|32) echo "laptop" ;;
        [Dd]esktop|[Tt]ower*|[Mm]ini*|[Ss]erver*|3|4|5|6|7|16|17|18|19)       echo "desktop" ;;
        [Aa]ll*[Ii]n*[Oo]ne|[Aa][Ii][Oo])                                       echo "aio" ;;
        *)                                                                        echo "unknown" ;;
    esac
}

# ── Health score ──────────────────────────────────────────────
calc_health() {
    local score=100 crit=0 warn=0 pfile
    for pfile in "$TMPD"/probs_*.ndjson; do
        [ -f "$pfile" ] || continue
        local c w
        c=$(grep -c '"severity":"critical"' "$pfile" 2>/dev/null || echo "0")
        w=$(grep -c '"severity":"warning"'  "$pfile" 2>/dev/null || echo "0")
        crit=$((crit + c)); warn=$((warn + w))
    done
    score=$((100 - crit * 20 - warn * 7))
    [ "$score" -lt 0 ] && score=0
    local label
    if   [ "$score" -ge 90 ]; then label="EXCELLENT"
    elif [ "$score" -ge 75 ]; then label="GOOD"
    elif [ "$score" -ge 55 ]; then label="FAIR"
    elif [ "$score" -ge 30 ]; then label="POOR"
    else                            label="CRITICAL"; fi
    printf '%d %s %d %d' "$score" "$label" "$((crit + warn))" "$crit"
}

# ── Assemble final JSON ───────────────────────────────────────
assemble_json() {
    local SCAN_DURATION=$(( SECONDS - SCAN_START ))
    local vendor model form_factor
    vendor=$(cat "$TMPD/machine_vendor" 2>/dev/null || echo "")
    model=$(cat "$TMPD/machine_model" 2>/dev/null || echo "")
    form_factor=$(get_form_factor)

    local health_info health_score health_label issues_count
    health_info=$(calc_health)
    health_score=$(echo "$health_info" | awk '{print $1}')
    health_label=$(echo "$health_info" | awk '{print $2}')
    issues_count=$(echo "$health_info" | awk '{print $3}')

    local ALL_PROBS="" pfile line
    for pfile in "$TMPD"/probs_*.ndjson; do
        [ -f "$pfile" ] || continue
        while IFS= read -r line; do
            [ -n "$line" ] && ALL_PROBS="${ALL_PROBS}${line},"
        done < "$pfile"
    done
    ALL_PROBS="${ALL_PROBS%,}"

    local J_CPU J_RAM J_STORAGE J_BATTERY J_GPU J_NETWORK J_THERMALS
    local J_AUDIO J_USB J_OS J_SECURITY J_MACHINE J_ANDROID J_NETSPEED J_IOS
    J_CPU=$(cat "$TMPD/json_cpu.json"        2>/dev/null || echo 'null')
    J_RAM=$(cat "$TMPD/json_ram.json"        2>/dev/null || echo 'null')
    J_STORAGE=$(cat "$TMPD/json_storage.json"     2>/dev/null || echo 'null')
    J_BATTERY=$(cat "$TMPD/json_battery.json"     2>/dev/null || echo 'null')
    J_GPU=$(cat "$TMPD/json_gpu.json"        2>/dev/null || echo 'null')
    J_NETWORK=$(cat "$TMPD/json_network.json"     2>/dev/null || echo 'null')
    J_THERMALS=$(cat "$TMPD/json_thermals.json"   2>/dev/null || echo 'null')
    J_AUDIO=$(cat "$TMPD/json_audio.json"    2>/dev/null || echo 'null')
    J_USB=$(cat "$TMPD/json_usb.json"        2>/dev/null || echo 'null')
    J_OS=$(cat "$TMPD/json_os.json"          2>/dev/null || echo 'null')
    J_SECURITY=$(cat "$TMPD/json_security.json"   2>/dev/null || echo 'null')
    J_MACHINE=$(cat "$TMPD/json_machine.json"     2>/dev/null || echo 'null')
    J_ANDROID=$(cat "$TMPD/json_android.json"     2>/dev/null || echo 'null')
    J_IOS=$(cat "$TMPD/json_ios.json"             2>/dev/null || echo 'null')
    J_NETSPEED=$(cat "$TMPD/json_netspeed.json"   2>/dev/null || echo 'null')

    cat > "$OUTPUT_FILE" <<JSON
{
  "platine_version": $(jstr "$PLATINE_VERSION"),
  "scan_id": $(jstr "$SCAN_ID"),
  "scanned_at": $(jstr "$SCANNED_AT"),
  "scan_duration_s": $(jnum "$SCAN_DURATION"),
  "health_score": $(jnum "$health_score"),
  "health_label": $(jstr "$health_label"),
  "issues_count": $(jnum "$issues_count"),
  "vendor": $(jstr "$vendor"),
  "model": $(jstr "$model"),
  "form_factor": $(jstr "$form_factor"),
  "machine": $J_MACHINE,
  "cpu": $J_CPU,
  "ram": $J_RAM,
  "storage": $J_STORAGE,
  "battery": $J_BATTERY,
  "gpu": $J_GPU,
  "network": $J_NETWORK,
  "thermals": $J_THERMALS,
  "audio": $J_AUDIO,
  "usb": $J_USB,
  "os": $J_OS,
  "security": $J_SECURITY,
  "android": $J_ANDROID,
  "ios": $J_IOS,
  "netspeed": $J_NETSPEED,
  "problems": [${ALL_PROBS}]
}
JSON

    if cmd python3; then
        python3 - "$OUTPUT_FILE" <<'PYEOF' 2>/dev/null || true
import json, re, sys
p = sys.argv[1]
with open(p) as f: c = f.read()
c = re.sub(r',(\s*[}\]])', r'\1', c)
try:
    data = json.loads(c)
    with open(p, 'w') as f: json.dump(data, f, ensure_ascii=False, separators=(',', ':'))
except Exception: pass
PYEOF
    fi
}

# ── Upload ────────────────────────────────────────────────────
upload_scan() {
    [ -f "$OUTPUT_FILE" ] || return 1
    local response
    response=$(curl -sf -m 30 -X POST "${PLATINE_API}/start" \
        -H "Content-Type: application/json" -d "@${OUTPUT_FILE}" 2>/dev/null) || return 1

    local SESSION_ID LIVE_URL
    SESSION_ID=$(echo "$response" | grep -oP '"session_id"\s*:\s*"\K[^"]+' || echo "")
    LIVE_URL=$(echo "$response"   | grep -oP '"live_url"\s*:\s*"\K[^"]+' || echo "")
    [ -z "${SESSION_ID:-}" ] && return 1

    printf '%s' "$SESSION_ID" > "$TMPD/session_id"
    printf '%s' "$LIVE_URL"   > "$TMPD/live_url"
    return 0
}

# ── QR code display ───────────────────────────────────────────
show_qr() {
    local url="${1:-}"
    { [ -z "$url" ] || [ "$SILENT" = true ]; } && return
    printf "\n  ${W}Scan with your phone:${N}\n"
    printf "  ${C}%s${N}\n\n" "$url"
    cmd qrencode && qrencode -t ANSIUTF8 -m 2 "$url" 2>/dev/null || true
}

# ── Live monitoring loop ──────────────────────────────────────
live_loop() {
    local SESSION_ID; SESSION_ID=$(cat "$TMPD/session_id" 2>/dev/null || echo "")
    [ -z "${SESSION_ID:-}" ] && return

    local LIVE_URL; LIVE_URL=$(cat "$TMPD/live_url" 2>/dev/null || echo "")
    [ "$SILENT" = false ] && {
        printf "${W}  ─────────────────────────────────────────────────────${N}\n"
        printf "  ${G}Live monitoring active — updates every 5s${N}\n"
        show_qr "$LIVE_URL"
    }

    local FAIL_COUNT=0
    while true; do
        sleep 5

        local CPU_TEMP="" hwmon hname tf lbl
        for hwmon in /sys/class/hwmon/hwmon*/; do
            [ -d "$hwmon" ] || continue
            hname=$(cat "${hwmon}name" 2>/dev/null || echo "")
            echo "$hname" | grep -qiE "coretemp|k10temp|zenpower" || continue
            for tf in "${hwmon}"temp*_input; do
                [ -f "$tf" ] || continue
                lbl=$(cat "${tf/_input/_label}" 2>/dev/null || echo "")
                echo "$lbl" | grep -qiE "Package|Tdie|^CPU$" || continue
                CPU_TEMP=$(awk '{printf "%.1f",$1/1000}' "$tf" 2>/dev/null || echo "")
                break 2
            done
        done

        local i1 t1 i2 t2 CPU_LOAD
        i1=$(awk '/^cpu /{idle=$6; for(i=2;i<=NF;i++) t+=$i; print idle}' /proc/stat 2>/dev/null || echo "0")
        t1=$(awk '/^cpu /{for(i=2;i<=NF;i++) t+=$i; print t}' /proc/stat 2>/dev/null || echo "1")
        sleep 0.3
        i2=$(awk '/^cpu /{idle=$6; for(i=2;i<=NF;i++) t+=$i; print idle}' /proc/stat 2>/dev/null || echo "0")
        t2=$(awk '/^cpu /{for(i=2;i<=NF;i++) t+=$i; print t}' /proc/stat 2>/dev/null || echo "1")
        CPU_LOAD=$(awk -v i1="${i1:-0}" -v t1="${t1:-1}" -v i2="${i2:-0}" -v t2="${t2:-1}" \
            'BEGIN{dt=t2-t1; di=i2-i1; if(dt>0) printf "%.0f",(1-di/dt)*100; else print 0}' \
            2>/dev/null || echo "0")

        local RAM_FREE_GB
        RAM_FREE_GB=$(awk '/^MemAvailable:/{printf "%.1f",$2/1024/1024}' /proc/meminfo 2>/dev/null || echo "")

        local patch now
        now=$(date '+%Y-%m-%dT%H:%M:%S')
        patch=$(printf '{"session_id":%s,"cpu_load":%s,"cpu_temp_c":%s,"ram_free_gb":%s,"updated_at":%s}' \
            "$(jstr "$SESSION_ID")" "$(jnum "${CPU_LOAD:-0}")" \
            "$(jnum "${CPU_TEMP:-}")" "$(jnum "${RAM_FREE_GB:-}")" "$(jstr "$now")")

        if curl -sf -m 8 -X POST "${PLATINE_API}/update" \
            -H "Content-Type: application/json" -d "$patch" >/dev/null 2>&1; then
            FAIL_COUNT=0
        else
            FAIL_COUNT=$((FAIL_COUNT + 1))
            local backoff; backoff=$(( FAIL_COUNT < 7 ? FAIL_COUNT * 5 : 30 ))
            sleep "$backoff"
        fi
    done
}

# ── Main ──────────────────────────────────────────────────────
main() {
    scan_machine

    scan_cpu      > "$TMPD/log_cpu.txt"      2>&1 & CPU_PID=$!
    scan_ram      > "$TMPD/log_ram.txt"      2>&1 & RAM_PID=$!
    scan_storage  > "$TMPD/log_storage.txt"  2>&1 & STO_PID=$!
    scan_battery  > "$TMPD/log_battery.txt"  2>&1 & BAT_PID=$!
    scan_gpu      > "$TMPD/log_gpu.txt"      2>&1 & GPU_PID=$!
    scan_network  > "$TMPD/log_network.txt"  2>&1 & NET_PID=$!
    scan_thermals > "$TMPD/log_thermals.txt" 2>&1 & THE_PID=$!
    scan_audio    > "$TMPD/log_audio.txt"    2>&1 & AUD_PID=$!
    scan_usb      > "$TMPD/log_usb.txt"      2>&1 & USB_PID=$!
    scan_os       > "$TMPD/log_os.txt"       2>&1 & OS_PID=$!
    scan_security > "$TMPD/log_security.txt" 2>&1 & SEC_PID=$!
    scan_android  > "$TMPD/log_android.txt"  2>&1 & AND_PID=$!
    scan_ios      > "$TMPD/log_ios.txt"      2>&1 & IOS_PID=$!

    while kill -0 $CPU_PID $RAM_PID $STO_PID $BAT_PID $GPU_PID $NET_PID $THE_PID 2>/dev/null; do
        render_ui; sleep 0.5
    done
    wait $CPU_PID $RAM_PID $STO_PID $BAT_PID $GPU_PID $NET_PID $THE_PID \
         $AUD_PID $USB_PID $OS_PID $SEC_PID $AND_PID $IOS_PID 2>/dev/null || true
    render_ui

    assemble_json

    local SCAN_DURATION=$(( SECONDS - SCAN_START ))
    local health_score health_label
    health_score=$(grep -oP '"health_score":\K[0-9]+' "$OUTPUT_FILE" 2>/dev/null | head -1 || echo "?")
    health_label=$(grep -oP '"health_label":"\K[^"]+' "$OUTPUT_FILE" 2>/dev/null | head -1 || echo "?")

    [ "$SILENT" = false ] && {
        printf "\n${G}  Scan complete in %ds${N}\n" "$SCAN_DURATION"
        printf "  JSON: ${W}%s${N}\n" "$OUTPUT_FILE"
        printf "\n  Health: ${W}%s/100${N} — ${B}%s${N}\n\n" "$health_score" "$health_label"
    }

    if setup_network; then
        # Network speed test now that we have internet
        [ "$SILENT" = false ] && printf "  ${C}Testing network speed...${N}\n"
        scan_netspeed > "$TMPD/log_netspeed.txt" 2>&1
        # Merge netspeed into output JSON (re-assemble with netspeed data now available)
        assemble_json

        if upload_scan; then
            local LIVE_URL; LIVE_URL=$(cat "$TMPD/live_url" 2>/dev/null || echo "")
            show_qr "$LIVE_URL"
            live_loop
        else
            [ "$SILENT" = false ] && \
                printf "${Y}  Upload failed — JSON saved locally: %s${N}\n" "$OUTPUT_FILE"
        fi
    else
        [ "$SILENT" = false ] && \
            printf "${Y}  No internet — JSON saved locally: %s${N}\n" "$OUTPUT_FILE"
        st_set netspeed error
        sum_set netspeed "No internet"
        printf '{"ping_ms":null,"packet_loss_pct":null,"download_mbps":null,"upload_mbps":null}' \
            > "$TMPD/json_netspeed.json"
    fi
}

main "$@"
