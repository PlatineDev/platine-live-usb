#!/usr/bin/env bash
# ============================================================
#  PLATINE LIVE USB - Hardware Scanner v1.0
#  github.com/Platine-dev/platine
#  platine.dev
#
#  Boot this from USB on any broken PC/laptop.
#  Detects ALL hardware, generates interactive map,
#  streams live data to your phone via WebSocket.
#
#  Usage: sudo bash platine-scan.sh [--silent] [--ws]
#  Output: platine_map.json (compatible with platine-v5.html)
# ============================================================

set -uo pipefail

# ── Version & ID ─────────────────────────────────────────────
PLATINE_VERSION="1.0.0"
SCAN_DATE=$(date '+%Y-%m-%d %H:%M:%S')
SCAN_ID=$(cat /proc/sys/kernel/random/uuid 2>/dev/null | tr -d '-' | cut -c1-8 | tr '[:lower:]' '[:upper:]' || echo "PLATINE1")
OUTPUT_DIR="${HOME}"
SILENT=false
WS_MODE=false
WS_PORT=8765

for arg in "$@"; do
    case "$arg" in
        --silent)    SILENT=true ;;
        --ws)        WS_MODE=true ;;
        --port=*)    WS_PORT="${arg#*=}" ;;
        --output=*)  OUTPUT_DIR="${arg#*=}" ;;
    esac
done

# ── Colors ───────────────────────────────────────────────────
R='\033[0;31m' Y='\033[1;33m' G='\033[0;32m'
C='\033[0;36m' W='\033[1;37m' D='\033[0;90m' N='\033[0m'
[ "$SILENT" = true ] && R='' Y='' G='' C='' W='' D='' N=''

log_header() {
    [ "$SILENT" = true ] && return
    clear
    printf "${W}"
    printf "  ██████╗ ██╗      █████╗ ████████╗██╗███╗   ██╗███████╗\n"
    printf "  ██╔══██╗██║     ██╔══██╗╚══██╔══╝██║████╗  ██║██╔════╝\n"
    printf "  ██████╔╝██║     ███████║   ██║   ██║██╔██╗ ██║█████╗  \n"
    printf "  ██╔═══╝ ██║     ██╔══██║   ██║   ██║██║╚██╗██║██╔══╝  \n"
    printf "  ██║     ███████╗██║  ██║   ██║   ██║██║ ╚████║███████╗\n"
    printf "  ╚═╝     ╚══════╝╚═╝  ╚═╝   ╚═╝   ╚═╝╚═╝  ╚═══╝╚══════╝\n"
    printf "${N}\n"
    printf "  ${C}Platine Live USB - Scanner v${PLATINE_VERSION}${N}\n"
    printf "  ${D}Scan ID: ${SCAN_ID}${N}\n"
    printf "  ${D}${SCAN_DATE}${N}\n\n"
    printf "  ${D}─────────────────────────────────────────────────────${N}\n\n"
}

log_section() { [ "$SILENT" = false ] && printf "\n  ${C}[ %s ]${N}\n" "$1"; }
log_ok()      { [ "$SILENT" = false ] && printf "  ${G}✓ %s${N}\n" "$1"; }
log_warn()    { [ "$SILENT" = false ] && printf "  ${Y}⚠ %s${N}\n" "$1"; }
log_err()     { [ "$SILENT" = false ] && printf "  ${R}✗ %s${N}\n" "$1"; }
log_info()    { [ "$SILENT" = false ] && printf "  ${D}· %s${N}\n" "$1"; }

# ── Helpers ──────────────────────────────────────────────────
cmd()     { command -v "$1" &>/dev/null; }
safe()    { "$@" 2>/dev/null || true; }
trim()    { echo "$1" | xargs; }

# JSON escaping - no jq needed
jstr() {
    local v="$1"
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    v="${v//$'\n'/ }"
    v="${v//$'\r'/}"
    printf '"%s"' "$v"
}
jnum() {
    local v="${1//[^0-9.-]/}"
    [ -z "$v" ] && echo "null" || echo "$v"
}

# ── Network & DNS setup (Alpine Live USB) ────────────────────
setup_network() {
    # Fix DNS first — Alpine live doesn't persist DNS
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf

    # Try to get IP on common interfaces if not already connected
    for iface in eth0 usb0 enp0s3 enp1s0; do
        if ip link show "$iface" 2>/dev/null | grep -q "UP"; then
            udhcpc -i "$iface" -t 5 -T 2 -q 2>/dev/null || true
        fi
    done

    # Load Realtek WiFi driver
    modprobe rtw_8723de 2>/dev/null || true
    modprobe rtw_8822be 2>/dev/null || true
    modprobe rtw_8822ce 2>/dev/null || true
}

# ── Auto-install tools ───────────────────────────────────────
install_tools() {
    # Use space-separated string instead of arrays (ash compatible)
    NEED=""
    cmd lshw      || NEED="$NEED lshw"
    cmd smartctl  || NEED="$NEED smartmontools"
    cmd dmidecode || NEED="$NEED dmidecode"
    cmd sensors   || NEED="$NEED lm-sensors"
    cmd lspci     || NEED="$NEED pciutils"
    cmd lsusb     || NEED="$NEED usbutils"
    cmd hdparm    || NEED="$NEED hdparm"
    cmd curl      || NEED="$NEED curl"
    cmd bash      || NEED="$NEED bash"

    if [ -n "$NEED" ]; then
        log_info "Installing tools:$NEED"
        if cmd apk; then
            # Set repos first
            echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/main" > /etc/apk/repositories
            echo "https://dl-cdn.alpinelinux.org/alpine/v3.19/community" >> /etc/apk/repositories
            apk add --no-cache $NEED 2>/dev/null || true
        elif cmd apt-get; then
            apt-get install -y -q $NEED 2>/dev/null || true
        elif cmd pacman;  then
            pacman -S --noconfirm $NEED 2>/dev/null || true
        elif cmd dnf; then
            dnf install -y $NEED 2>/dev/null || true
        fi
    fi
}

# ── Root warning ─────────────────────────────────────────────
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        log_warn "Not running as root - some data will be unavailable"
        log_info "Tip: sudo bash platine-scan.sh"
    fi
}

# ── WebSocket server ─────────────────────────────────────────
start_ws_server() {
    ! cmd python3 && log_warn "python3 not found - WebSocket disabled" && return

    local ip
    ip=$(ip route get 8.8.8.8 2>/dev/null | awk '{print $7; exit}' || echo "127.0.0.1")

    # Write ws-server to temp file using printf (avoids bash parsing Python as bash syntax)
    printf '%s\n' \
        'import sys, os, asyncio, json' \
        'PORT = int(sys.argv[1])' \
        'DATA_FILE = sys.argv[2]' \
        'try:' \
        '    import websockets; USE_WS = True' \
        'except ImportError:' \
        '    USE_WS = False' \
        'if USE_WS:' \
        '    async def handler(ws, path):' \
        '        last = 0' \
        '        try:' \
        '            while True:' \
        '                if os.path.exists(DATA_FILE):' \
        '                    mtime = os.path.getmtime(DATA_FILE)' \
        '                    if mtime != last:' \
        '                        last = mtime' \
        '                        with open(DATA_FILE) as f: data = f.read()' \
        '                        await ws.send(data)' \
        '                await asyncio.sleep(3)' \
        '        except Exception: pass' \
        '    async def main():' \
        '        async with websockets.serve(handler, "0.0.0.0", PORT):' \
        '            await asyncio.Future()' \
        '    asyncio.run(main())' \
        'else:' \
        '    from http.server import HTTPServer, BaseHTTPRequestHandler' \
        '    class H(BaseHTTPRequestHandler):' \
        '        def log_message(self, *a): pass' \
        '        def do_GET(self):' \
        '            try:' \
        '                with open(DATA_FILE) as f: d = f.read()' \
        '                self.send_response(200)' \
        '                self.send_header("Content-Type","application/json")' \
        '                self.send_header("Access-Control-Allow-Origin","*")' \
        '                self.end_headers()' \
        '                self.wfile.write(d.encode())' \
        '            except: self.send_response(503); self.end_headers()' \
        '    HTTPServer(("0.0.0.0", PORT), H).serve_forever()' \
        > "$TMPD/ws_server.py"

    python3 "$TMPD/ws_server.py" "$WS_PORT" "$LIVE_FILE" &

    WS_PID=$!
    log_ok "Live server started (PID $WS_PID)"
    printf "\n  ${W}┌─────────────────────────────────────────────────────┐${N}\n"
    printf   "  ${W}│  Open on your phone (same WiFi):                    │${N}\n"
    printf   "  ${W}│  ws://%-45s│${N}\n"  "${ip}:${WS_PORT}"
    printf   "  ${W}│  http://%-44s│${N}\n" "${ip}:${WS_PORT}"
    printf   "  ${W}└─────────────────────────────────────────────────────┘${N}\n\n"
}

# ── Temp dir ─────────────────────────────────────────────────
TMPD=$(mktemp -d /tmp/platine-XXXXXX)
LIVE_FILE="$TMPD/platine_live.json"
trap 'rm -rf "$TMPD"' EXIT

# Write the live-patch Python helper
printf '%s\n' \
    'import sys, json' \
    'try:' \
    '    src, dst, qt_json, load, ram, ts = sys.argv[1:]' \
    '    with open(src) as f: d = json.load(f)' \
    '    if qt_json:' \
    '        pairs = [p.split(":", 1) for p in qt_json.split(",") if ":" in p]' \
    '        d.setdefault("thermals", {})["live_temps"] = {k.strip(chr(34)): float(v) for k, v in pairs}' \
    '    d.setdefault("performance", {})["live_cpu_load"] = float(load)' \
    '    d.setdefault("performance", {})["live_ram_free_gb"] = float(ram)' \
    '    d["scan_date"] = ts' \
    '    with open(dst, "w") as f: json.dump(d, f)' \
    'except: pass' \
    > /tmp/platine_patch.py

# ============================================================
# BOOT
# ============================================================
log_header
check_root
setup_network
install_tools
[ "$WS_MODE" = true ] && start_ws_server

# ============================================================
# 1. MACHINE IDENTITY
# ============================================================
log_section "MACHINE IDENTITY"

dmi() { dmidecode -s "$1" 2>/dev/null | head -1 | xargs || echo ""; }
dmi_field() { dmidecode -t "$1" 2>/dev/null | grep -m1 "$2:" | sed 's/.*: //' | xargs || echo ""; }

MANUFACTURER=$(dmi "system-manufacturer")
MODEL=$(dmi "system-product-name")
MODEL_VERSION=$(dmi "system-version")
BOARD_PRODUCT=$(dmi "baseboard-product-name")
BOARD_VENDOR=$(dmi "baseboard-manufacturer")
BOARD_VERSION=$(dmi "baseboard-version")
BOARD_SERIAL=$(dmi "baseboard-serial-number")
SYSTEM_SERIAL=$(dmi "system-serial-number")
BIOS_VENDOR=$(dmi "bios-vendor")
BIOS_VERSION=$(dmi "bios-version")
BIOS_DATE=$(dmi "bios-release-date")
CHASSIS_TYPE=$(dmi_field 3 "Type")

# Fallback via /sys if dmidecode not available
[ -z "$MANUFACTURER" ] && MANUFACTURER=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null | xargs || echo "Unknown")
[ -z "$MODEL" ]        && MODEL=$(cat /sys/class/dmi/id/product_name 2>/dev/null | xargs || echo "Unknown")

MODEL_ID=$(printf '%s_%s' "$MANUFACTURER" "$MODEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | sed 's/__*/_/g')

log_ok "Manufacturer : $MANUFACTURER"
log_ok "Model        : $MODEL"
log_ok "Board        : $BOARD_PRODUCT $BOARD_VERSION"
log_ok "Serial       : $SYSTEM_SERIAL"
log_ok "Chassis      : $CHASSIS_TYPE"
log_ok "BIOS         : $BIOS_VERSION ($BIOS_DATE)"

# ============================================================
# 2. CPU
# ============================================================
log_section "CPU"

CPU_MODEL=$(grep -m1 "model name" /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs || echo "Unknown")
CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "")
CPU_PHYSICAL=$(grep "^physical id" /proc/cpuinfo 2>/dev/null | sort -u | wc -l || echo "1")
[ "$CPU_PHYSICAL" -lt 1 ] && CPU_PHYSICAL=1
CPU_CORES=$(grep "^cpu cores" /proc/cpuinfo 2>/dev/null | head -1 | awk '{print $NF}' || echo "1")
CPU_LOGICAL=$(nproc 2>/dev/null || grep -c "^processor" /proc/cpuinfo 2>/dev/null || echo "1")
CPU_THREADS=$((CPU_LOGICAL / CPU_PHYSICAL))
CPU_STEPPING=$(grep -m1 "stepping" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "")
CPU_MICROCODE=$(grep -m1 "microcode" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "")
CPU_FAMILY=$(grep -m1 "cpu family" /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs || echo "")
CPU_ARCH=$(uname -m 2>/dev/null || echo "x86_64")

CPU_MAX_MHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq 2>/dev/null | awk '{printf "%.0f",$1/1000}' || \
              grep -m1 "cpu MHz" /proc/cpuinfo 2>/dev/null | awk -F: '{printf "%.0f",$2}' || echo "0")
CPU_CUR_MHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq 2>/dev/null | awk '{printf "%.0f",$1/1000}' || echo "$CPU_MAX_MHZ")
CPU_MIN_MHZ=$(cat /sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_min_freq 2>/dev/null | awk '{printf "%.0f",$1/1000}' || echo "0")
CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "unknown")

# L2/L3 cache
CPU_L2=$(lscpu 2>/dev/null | grep "^L2 cache" | awk '{print $3}' || echo "")
CPU_L3=$(lscpu 2>/dev/null | grep "^L3 cache" | awk '{print $3}' || echo "")

# CPU temperature - try multiple sources
CPU_TEMP="null"
for hwmon in /sys/class/hwmon/hwmon*/; do
    hname=$(cat "${hwmon}name" 2>/dev/null || echo "")
    echo "$hname" | grep -qiE "coretemp|k10temp|zenpower|cpu_thermal" || continue
    for tf in "${hwmon}"temp*_input; do
        [ -f "$tf" ] || continue
        label=$(cat "${tf/_input/_label}" 2>/dev/null || echo "")
        echo "$label" | grep -qiE "Package|Tdie|Tccd|CPU" || continue
        raw=$(cat "$tf" 2>/dev/null || echo "0")
        CPU_TEMP=$(awk -v r="$raw" 'BEGIN{printf "%.1f",r/1000}')
        break 2
    done
done
# Fallback: first available temp
if [ "$CPU_TEMP" = "null" ]; then
    for tf in /sys/class/hwmon/hwmon*/temp1_input; do
        [ -f "$tf" ] || continue
        raw=$(cat "$tf" 2>/dev/null || echo "0")
        CPU_TEMP=$(awk -v r="$raw" 'BEGIN{printf "%.1f",r/1000}')
        break
    done
fi

# Throttle count
CPU_THROTTLE=$(cat /sys/devices/system/cpu/cpu0/thermal_throttle/core_throttle_count 2>/dev/null || echo "0")

# CPU flags
CPU_FLAGS=$(grep -m1 "^flags" /proc/cpuinfo 2>/dev/null | cut -d: -f2- || echo "")
HAS_VT=$(echo "$CPU_FLAGS" | grep -qwE "vmx|svm" && echo "true" || echo "false")
HAS_AES=$(echo "$CPU_FLAGS" | grep -qw "aes" && echo "true" || echo "false")
HAS_AVX=$(echo "$CPU_FLAGS" | grep -qw "avx" && echo "true" || echo "false")
HAS_AVX2=$(echo "$CPU_FLAGS" | grep -qw "avx2" && echo "true" || echo "false")

# Load
CPU_LOAD=$(top -bn1 2>/dev/null | grep "^%Cpu" | awk '{printf "%.1f",100-$8}' || echo "0")

# Frequency ratio (throttle detection)
CPU_FREQ_RATIO="null"
if [ "$CPU_MAX_MHZ" -gt 0 ] 2>/dev/null && [ "$CPU_CUR_MHZ" -gt 0 ] 2>/dev/null; then
    CPU_FREQ_RATIO=$(awk -v cur="$CPU_CUR_MHZ" -v max="$CPU_MAX_MHZ" 'BEGIN{printf "%.0f",(cur/max)*100}')
fi

# Log
if [ "$CPU_TEMP" != "null" ]; then
    is_crit=$(awk -v t="$CPU_TEMP" 'BEGIN{print (t>90)?1:0}')
    is_high=$(awk -v t="$CPU_TEMP" 'BEGIN{print (t>75)?1:0}')
    if   [ "$is_crit" = "1" ]; then log_err  "CPU: $CPU_MODEL - TEMP CRITICAL: ${CPU_TEMP}°C"
    elif [ "$is_high" = "1" ]; then log_warn "CPU: $CPU_MODEL - TEMP HIGH: ${CPU_TEMP}°C"
    else                            log_ok   "CPU: $CPU_MODEL - ${CPU_TEMP}°C · ${CPU_CORES}C/${CPU_LOGICAL}T"
    fi
else
    log_ok "CPU: $CPU_MODEL · ${CPU_CORES}C/${CPU_LOGICAL}T · ${CPU_MAX_MHZ}MHz"
fi

CPU_JSON=$(printf '[{"name":%s,"vendor":%s,"architecture":%s,"physical_cpus":%s,"cores":%s,"logical_processors":%s,"threads_per_core":%s,"base_clock_mhz":%s,"current_clock_mhz":%s,"min_clock_mhz":%s,"governor":%s,"l2_cache":%s,"l3_cache":%s,"temp_celsius":%s,"load_percent":%s,"family":%s,"stepping":%s,"microcode":%s,"virtualization":%s,"aes_ni":%s,"avx":%s,"avx2":%s,"throttle_count":%s,"freq_ratio_pct":%s}]' \
    "$(jstr "$CPU_MODEL")" "$(jstr "$CPU_VENDOR")" "$(jstr "$CPU_ARCH")" "$CPU_PHYSICAL" \
    "$(jnum "$CPU_CORES")" "$(jnum "$CPU_LOGICAL")" "$(jnum "$CPU_THREADS")" \
    "$(jnum "$CPU_MAX_MHZ")" "$(jnum "$CPU_CUR_MHZ")" "$(jnum "$CPU_MIN_MHZ")" \
    "$(jstr "$CPU_GOVERNOR")" "$(jstr "$CPU_L2")" "$(jstr "$CPU_L3")" \
    "$CPU_TEMP" "$(jnum "$CPU_LOAD")" "$(jstr "$CPU_FAMILY")" "$(jstr "$CPU_STEPPING")" \
    "$(jstr "$CPU_MICROCODE")" "$HAS_VT" "$HAS_AES" "$HAS_AVX" "$HAS_AVX2" \
    "$(jnum "$CPU_THROTTLE")" "$CPU_FREQ_RATIO")

# ============================================================
# 3. MEMORY - SLOT BY SLOT
# ============================================================
log_section "MEMORY"

TOTAL_RAM_GB=$(awk '/MemTotal/{printf "%.1f",$2/1048576}' /proc/meminfo)
FREE_RAM_GB=$(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)
USED_RAM_GB=$(awk "BEGIN{printf \"%.1f\",$TOTAL_RAM_GB - $FREE_RAM_GB}")
RAM_PCT=$(awk "BEGIN{printf \"%.0f\",($USED_RAM_GB/$TOTAL_RAM_GB)*100}" 2>/dev/null || echo "0")

RAM_MODS_JSON=""
USED_SLOTS=0
TOTAL_SLOTS=0
MAX_CAPACITY=""

if cmd dmidecode; then
    # Parse Memory Device blocks via temp file
    DMI_TMP="$TMPD/dmi17.txt"
    { dmidecode -t 17 2>/dev/null; echo "Memory Device"; } > "$DMI_TMP"
    current_block=""
    while IFS= read -r line; do
        if echo "$line" | grep -q "^Memory Device$"; then
            if [ -n "$current_block" ]; then
                SIZE=$(echo "$current_block" | grep -m1 "Size:" | sed 's/.*Size: //' | xargs)
                if echo "$SIZE" | grep -qE "^[0-9]+"; then
                    SLOT=$(echo "$current_block" | grep -m1 "Locator:" | grep -v "Bank" | sed 's/.*Locator: //' | xargs)
                    BANK=$(echo "$current_block" | grep -m1 "Bank Locator:" | sed 's/.*Bank Locator: //' | xargs)
                    MTYPE=$(echo "$current_block" | grep -m1 "Type:" | grep -v "Error\|Correction\|Factor\|Detail" | sed 's/.*Type: //' | xargs)
                    SPEED=$(echo "$current_block" | grep -m1 "Speed:" | grep -oP '[0-9]+' | head -1 || echo "0")
                    CFGSPD=$(echo "$current_block" | grep -m1 "Configured.*Speed:" | grep -oP '[0-9]+' | head -1 || echo "0")
                    MFG=$(echo "$current_block" | grep -m1 "Manufacturer:" | sed 's/.*Manufacturer: //' | xargs)
                    PART=$(echo "$current_block" | grep -m1 "Part Number:" | sed 's/.*Part Number: //' | xargs)
                    SERIAL_RAM=$(echo "$current_block" | grep -m1 "Serial Number:" | sed 's/.*Serial Number: //' | xargs)
                    VOLT=$(echo "$current_block" | grep -m1 "Configured Voltage:" | grep -oP '[0-9.]+' | head -1 || echo "")
                    FORM=$(echo "$current_block" | grep -m1 "Form Factor:" | sed 's/.*Form Factor: //' | xargs)
                    DW=$(echo "$current_block" | grep -m1 "Data Width:" | grep -oP '[0-9]+' | head -1 || echo "64")
                    TW=$(echo "$current_block" | grep -m1 "Total Width:" | grep -oP '[0-9]+' | head -1 || echo "64")
                    SIZE_GB=$(echo "$SIZE" | awk '{u=substr($0,length($0)); n=substr($0,1,length($0)-2)+0; if(u=="GB")printf "%.0f",n; else if(u=="MB")printf "%.1f",n/1024; else printf "0"}')
                    ECC=$([ "${TW:-64}" -gt "${DW:-64}" ] && echo "true" || echo "false")
                    USED_SLOTS=$((USED_SLOTS+1))
                    [ -n "$RAM_MODS_JSON" ] && RAM_MODS_JSON+=","
                    RAM_MODS_JSON+="{\"slot\":$(jstr "$SLOT"),\"bank\":$(jstr "$BANK"),\"size_gb\":$(jnum "$SIZE_GB"),\"type\":$(jstr "$MTYPE"),\"form_factor\":$(jstr "$FORM"),\"speed_mhz\":$(jnum "$SPEED"),\"configured_mhz\":$(jnum "$CFGSPD"),\"manufacturer\":$(jstr "$MFG"),\"part_number\":$(jstr "$PART"),\"serial\":$(jstr "$SERIAL_RAM"),\"voltage\":$(jstr "${VOLT}V"),\"ecc\":$ECC}"
                    log_ok "RAM: $SLOT - ${SIZE_GB}GB $MTYPE @ ${SPEED}MHz - $MFG $PART"
                fi
            fi
            current_block=""
        else
            current_block+="$line"$'\n'
        fi
    done < "$DMI_TMP"

    MAX_CAPACITY=$(dmidecode -t 16 2>/dev/null | grep "Maximum Capacity:" | head -1 | sed 's/.*Capacity: //' | xargs || echo "")
    ARR_SLOTS=$(dmidecode -t 16 2>/dev/null | grep "Number Of Devices:" | grep -oP '[0-9]+' | head -1 || echo "")
    [ -n "$ARR_SLOTS" ] && TOTAL_SLOTS=$ARR_SLOTS || TOTAL_SLOTS=$USED_SLOTS
fi

# Dual channel detection
DUAL_CHANNEL="false"
CHANNEL_NOTE="Cannot determine"
if [ "$USED_SLOTS" -ge 2 ]; then
    DUAL_CHANNEL="true"
    CHANNEL_NOTE="Dual-channel likely active ($USED_SLOTS DIMMs installed)"
elif [ "$USED_SLOTS" -eq 1 ]; then
    CHANNEL_NOTE="Single-channel - add matching DIMM in slot B for dual-channel"
    log_warn "$CHANNEL_NOTE"
fi

# XMP check
XMP_NOTE=""
if [ "$USED_SLOTS" -ge 1 ]; then
    SPD=$(echo "$RAM_MODS_JSON" | grep -oP '"speed_mhz":\K[0-9]+' | head -1 || echo "0")
    CFG=$(echo "$RAM_MODS_JSON" | grep -oP '"configured_mhz":\K[0-9]+' | head -1 || echo "0")
    if [ "$SPD" -gt 0 ] 2>/dev/null && [ "$CFG" -gt 0 ] 2>/dev/null && [ "$CFG" -lt "$SPD" ] 2>/dev/null; then
        XMP_NOTE="RAM at ${CFG}MHz vs rated ${SPD}MHz - enable XMP/DOCP in BIOS"
        log_warn "$XMP_NOTE"
    fi
fi

log_ok "Total RAM: ${TOTAL_RAM_GB}GB - Used: ${USED_RAM_GB}GB (${RAM_PCT}%)"

MEMORY_JSON=$(printf '{"total_gb":%s,"used_gb":%s,"free_gb":%s,"used_pct":%s,"total_slots":%s,"used_slots":%s,"max_capacity":%s,"dual_channel":%s,"channel_note":%s,"xmp_note":%s,"modules":[%s]}' \
    "$(jnum "$TOTAL_RAM_GB")" "$(jnum "$USED_RAM_GB")" "$(jnum "$FREE_RAM_GB")" "$(jnum "$RAM_PCT")" \
    "$(jnum "${TOTAL_SLOTS:-$USED_SLOTS}")" "$USED_SLOTS" "$(jstr "${MAX_CAPACITY:-Unknown}")" \
    "$DUAL_CHANNEL" "$(jstr "$CHANNEL_NOTE")" "$(jstr "$XMP_NOTE")" "$RAM_MODS_JSON")

# ============================================================
# 4. STORAGE - SMART + PARTITIONS
# ============================================================
log_section "STORAGE"

DRIVES_JSON=""

for dev in $(lsblk -d -n -o NAME,TYPE 2>/dev/null | awk '$2=="disk"{print $1}' | sort); do
    DEV_PATH="/dev/$dev"
    [ -b "$DEV_PATH" ] || continue

    SZ_BYTES=$(lsblk -d -n -o SIZE --bytes "$DEV_PATH" 2>/dev/null | tr -d ' ' || echo "0")
    SZ_GB=$(awk -v b="$SZ_BYTES" 'BEGIN{printf "%.1f",b/1073741824}')
    DISK_MODEL=$(cat "/sys/block/$dev/device/model" 2>/dev/null | xargs || \
                 lsblk -d -n -o MODEL "$DEV_PATH" 2>/dev/null | xargs || echo "Unknown")
    DISK_VENDOR=$(cat "/sys/block/$dev/device/vendor" 2>/dev/null | xargs || echo "")
    DISK_SERIAL=$(udevadm info --query=all --name="$DEV_PATH" 2>/dev/null | grep "ID_SERIAL_SHORT=" | cut -d= -f2 || \
                  lsblk -d -n -o SERIAL "$DEV_PATH" 2>/dev/null | xargs || echo "")
    DISK_FW=$(cat "/sys/block/$dev/device/rev" 2>/dev/null | xargs || echo "")
    ROTA=$(cat "/sys/block/$dev/queue/rotational" 2>/dev/null || echo "0")
    MEDIA_TYPE=$([ "$ROTA" = "1" ] && echo "HDD" || echo "SSD/NVMe")
    TRANSPORT=$(lsblk -d -n -o TRAN "$DEV_PATH" 2>/dev/null | xargs || echo "")

    # SMART
    SMART_STATUS="Unknown"
    SMART_FAILING="false"
    SMART_HOURS="null"
    SMART_TEMP_DISK="null"
    SMART_REALLOCATED="null"
    SMART_PENDING="null"
    SMART_UNCORRECTABLE="null"
    SMART_WEAR="null"
    SMART_ATTRS_JSON=""

    if cmd smartctl; then
        SOUT=$(smartctl -a "$DEV_PATH" 2>/dev/null || echo "")
        if [ -n "$SOUT" ]; then
            echo "$SOUT" | grep -q "SMART overall-health.*PASSED" && SMART_STATUS="OK"   && SMART_FAILING="false"
            echo "$SOUT" | grep -q "SMART overall-health.*FAILED" && SMART_STATUS="FAILING" && SMART_FAILING="true"

            SMART_HOURS=$(echo "$SOUT" | grep -iE "Power_On_Hours" | grep -oP '\s[0-9]+$' | tr -d ' ' | head -1 || echo "null")
            SMART_TEMP_DISK=$(echo "$SOUT" | grep -iE "Temperature_Celsius|Airflow_Temp" | grep -oP '[0-9]+' | head -1 || echo "null")
            SMART_REALLOCATED=$(echo "$SOUT" | grep -i "Reallocated_Sector" | grep -oP '\s[0-9]+$' | tr -d ' ' | head -1 || echo "null")
            SMART_PENDING=$(echo "$SOUT" | grep -i "Current_Pending_Sector" | grep -oP '\s[0-9]+$' | tr -d ' ' | head -1 || echo "null")
            SMART_UNCORRECTABLE=$(echo "$SOUT" | grep -i "Offline_Uncorrectable" | grep -oP '\s[0-9]+$' | tr -d ' ' | head -1 || echo "null")
            SMART_WEAR=$(echo "$SOUT" | grep -iE "Wear_Leveling|Media_Wearout|Percent_Lifetime" | grep -oP '\s[0-9]+$' | tr -d ' ' | head -1 || echo "null")

            # Key attributes
            ATTR_LINES=$(echo "$SOUT" | grep -E "^[[:space:]]*[0-9]+ " | head -20 || echo "")
            ATTR_TMP="$TMPD/smart_attrs.txt"
            echo "$ATTR_LINES" > "$ATTR_TMP"
            while IFS= read -r al; do
                [ -z "$al" ] && continue
                AID=$(echo "$al" | awk '{print $1}')
                ANAME=$(echo "$al" | awk '{print $2}')
                AVAL=$(echo "$al" | awk '{print $4}')
                AWST=$(echo "$al" | awk '{print $5}')
                ARAW=$(echo "$al" | awk '{print $NF}')
                [ -n "$SMART_ATTRS_JSON" ] && SMART_ATTRS_JSON+=","
                SMART_ATTRS_JSON+="{\"id\":$(jnum "$AID"),\"name\":$(jstr "$ANAME"),\"value\":$(jnum "$AVAL"),\"worst\":$(jnum "$AWST"),\"raw\":$(jnum "$ARAW")}"
            done < "$ATTR_TMP"
        fi
    fi

    # Partitions
    PARTS_JSON=""
    PART_LINES=$(lsblk -rn -o NAME,FSTYPE,FSSIZE,FSAVAIL,MOUNTPOINT "$DEV_PATH" 2>/dev/null | grep -v "^$" || echo "")
    PART_TMP="$TMPD/parts.txt"
    echo "$PART_LINES" > "$PART_TMP"
    while IFS= read -r pl; do
        [ -z "$pl" ] && continue
        PN=$(echo "$pl" | awk '{print $1}')
        PFS=$(echo "$pl" | awk '{print $2}')
        PSZ=$(echo "$pl" | awk '{print $3}')
        PAV=$(echo "$pl" | awk '{print $4}')
        PMT=$(echo "$pl" | awk '{print $5}')
        PLABEL=$(lsblk -n -o LABEL "/dev/$PN" 2>/dev/null | head -1 | xargs || echo "")
        [ -n "$PARTS_JSON" ] && PARTS_JSON+=","
        PARTS_JSON+="{\"name\":$(jstr "$PN"),\"mount\":$(jstr "$PMT"),\"filesystem\":$(jstr "$PFS"),\"label\":$(jstr "$PLABEL"),\"size\":$(jstr "$PSZ"),\"available\":$(jstr "$PAV")}"
    done < "$PART_TMP"

    if [ "$SMART_FAILING" = "true" ]; then
        log_err "DISK: $DISK_MODEL - ${SZ_GB}GB [$TRANSPORT] - ⚠ SMART FAILING! BACK UP NOW"
    else
        log_ok "DISK: $DISK_MODEL - ${SZ_GB}GB [$TRANSPORT] - SMART: $SMART_STATUS"
    fi

    [ -n "$DRIVES_JSON" ] && DRIVES_JSON+=","
    DRIVES_JSON+=$(printf '{"device":%s,"model":%s,"vendor":%s,"serial":%s,"firmware":%s,"transport":%s,"media_type":%s,"size_gb":%s,"smart_status":%s,"smart_failing":%s,"smart_power_on_hours":%s,"smart_temp_celsius":%s,"smart_reallocated":%s,"smart_pending":%s,"smart_uncorrectable":%s,"smart_wear_level":%s,"smart_attributes":[%s],"partitions":[%s]}' \
        "$(jstr "$DEV_PATH")" "$(jstr "$DISK_MODEL")" "$(jstr "$DISK_VENDOR")" "$(jstr "$DISK_SERIAL")" \
        "$(jstr "$DISK_FW")" "$(jstr "$TRANSPORT")" "$(jstr "$MEDIA_TYPE")" "$(jnum "$SZ_GB")" \
        "$(jstr "$SMART_STATUS")" "$SMART_FAILING" "${SMART_HOURS:-null}" "${SMART_TEMP_DISK:-null}" \
        "${SMART_REALLOCATED:-null}" "${SMART_PENDING:-null}" "${SMART_UNCORRECTABLE:-null}" "${SMART_WEAR:-null}" \
        "$SMART_ATTRS_JSON" "$PARTS_JSON")
done

STORAGE_JSON="{\"drives\":[${DRIVES_JSON}]}"

# ============================================================
# 5. GPU
# ============================================================
log_section "GPU"

GPU_JSON=""

if cmd lspci; then
    lspci 2>/dev/null | grep -iE "VGA|3D controller|Display" > "$TMPD/gpus.txt" || true
    while IFS= read -r line; do
        GSLOT=$(echo "$line" | cut -d' ' -f1)
        GNAME=$(echo "$line" | sed 's/^[^ ]* [^:]*: //')
        GVENDOR=$(echo "$GNAME" | awk '{print $1}')
        IS_IGPU="false"
        echo "$GNAME" | grep -qiE "Intel|UHD|HD Graphics|Vega|Radeon Graphics" && IS_IGPU="true"

        GPCIID=$(lspci -n -s "$GSLOT" 2>/dev/null | awk '{print $3}' || echo "")
        GDRIVER=$(lspci -v -s "$GSLOT" 2>/dev/null | grep "Kernel driver" | sed 's/.*: //' | xargs || echo "")
        GSUBSYS=$(lspci -v -s "$GSLOT" 2>/dev/null | grep "Subsystem:" | sed 's/.*Subsystem: //' | xargs || echo "")

        # VRAM
        GVRAM="null"
        for dm in /sys/class/drm/card*/; do
            vmf="${dm}device/mem_info_vram_total"
            [ -f "$vmf" ] || continue
            vb=$(cat "$vmf" 2>/dev/null || echo "0")
            [ "$vb" -gt 0 ] 2>/dev/null && GVRAM=$(awk -v b="$vb" 'BEGIN{printf "%.0f",b/1048576}') && break
        done

        # GPU temp
        GTEMP="null"
        for hwm in /sys/class/hwmon/hwmon*/; do
            hn=$(cat "${hwm}name" 2>/dev/null || echo "")
            echo "$hn" | grep -qiE "amdgpu|nvidia|radeon" || continue
            for tf in "${hwm}"temp*_input; do
                [ -f "$tf" ] || continue
                tr=$(cat "$tf" 2>/dev/null || echo "0")
                GTEMP=$(awk -v r="$tr" 'BEGIN{printf "%.1f",r/1000}')
                break 2
            done
        done

        # GPU load (amdgpu)
        GLOAD="null"
        for gb in /sys/class/drm/card*/device/gpu_busy_percent; do
            [ -f "$gb" ] && GLOAD=$(cat "$gb" 2>/dev/null || echo "null") && break
        done

        log_ok "GPU: $GNAME - VRAM: ${GVRAM}MB - Driver: $GDRIVER"

        [ -n "$GPU_JSON" ] && GPU_JSON+=","
        GPU_JSON+=$(printf '{"name":%s,"vendor":%s,"pci_slot":%s,"pci_id":%s,"subsystem":%s,"driver":%s,"vram_mb":%s,"temp_celsius":%s,"gpu_load_pct":%s,"is_integrated":%s}' \
            "$(jstr "$GNAME")" "$(jstr "$GVENDOR")" "$(jstr "$GSLOT")" "$(jstr "$GPCIID")" \
            "$(jstr "$GSUBSYS")" "$(jstr "$GDRIVER")" "$GVRAM" "$GTEMP" "$GLOAD" "$IS_IGPU")
    done < "$TMPD/gpus.txt"
fi

GPU_JSON="[${GPU_JSON}]"

# ============================================================
# 6. BATTERY
# ============================================================
log_section "BATTERY"

BAT_JSON=""
IS_LAPTOP="false"
POWER_SOURCE="Unknown"

# AC status
[ -f /sys/class/power_supply/AC/online ] && \
    ([ "$(cat /sys/class/power_supply/AC/online 2>/dev/null)" = "1" ] && POWER_SOURCE="AC Adapter" || POWER_SOURCE="Battery")

for batdir in /sys/class/power_supply/BAT*; do
    [ -d "$batdir" ] || continue
    IS_LAPTOP="true"
    BNAME=$(basename "$batdir")
    BSTATUS=$(cat "$batdir/status"    2>/dev/null || echo "Unknown")
    BCAP=$(cat "$batdir/capacity"     2>/dev/null || echo "0")
    BDESIGN=$(cat "$batdir/energy_full_design" 2>/dev/null || cat "$batdir/charge_full_design" 2>/dev/null || echo "0")
    BFULL=$(cat "$batdir/energy_full"  2>/dev/null || cat "$batdir/charge_full" 2>/dev/null  || echo "0")
    BVOLT=$(cat "$batdir/voltage_now"  2>/dev/null || echo "0")
    BMANUF=$(cat "$batdir/manufacturer" 2>/dev/null || echo "")
    BMODEL=$(cat "$batdir/model_name"   2>/dev/null || echo "")
    BSERIAL=$(cat "$batdir/serial_number" 2>/dev/null || echo "")
    BTECH=$(cat "$batdir/technology"    2>/dev/null || echo "")
    BCYCLES=$(cat "$batdir/cycle_count" 2>/dev/null || echo "null")
    BPOW=$(cat "$batdir/power_now" 2>/dev/null || cat "$batdir/current_now" 2>/dev/null || echo "0")

    BHEALTH="null"
    BDESIGN_WH="0"
    BFULL_WH="0"
    BVOLT_V="0"
    BPOW_W="0"

    if [ "$BDESIGN" -gt 0 ] 2>/dev/null && [ "$BFULL" -gt 0 ] 2>/dev/null; then
        BHEALTH=$(awk -v f="$BFULL" -v d="$BDESIGN" 'BEGIN{printf "%.0f",(f/d)*100}')
        BDESIGN_WH=$(awk -v v="$BDESIGN" 'BEGIN{printf "%.2f",v/1000000}')
        BFULL_WH=$(awk -v v="$BFULL" 'BEGIN{printf "%.2f",v/1000000}')
    fi
    [ "$BVOLT" -gt 0 ] 2>/dev/null && BVOLT_V=$(awk -v v="$BVOLT" 'BEGIN{printf "%.3f",v/1000000}')
    [ "$BPOW"  -gt 0 ] 2>/dev/null && BPOW_W=$(awk -v v="$BPOW" 'BEGIN{printf "%.2f",v/1000000}')

    if [ "$BHEALTH" != "null" ]; then
        if [ "$BHEALTH" -lt 50 ] 2>/dev/null; then log_err  "Battery: $BNAME - Health: ${BHEALTH}% CRITICAL"
        elif [ "$BHEALTH" -lt 75 ] 2>/dev/null; then log_warn "Battery: $BNAME - Health: ${BHEALTH}%"
        else log_ok "Battery: $BNAME - Health: ${BHEALTH}% - $BSTATUS - ${BCAP}%"; fi
    else
        log_ok "Battery: $BNAME - $BSTATUS - ${BCAP}%"
    fi

    [ -n "$BAT_JSON" ] && BAT_JSON+=","
    BAT_JSON+=$(printf '{"name":%s,"status":%s,"charge_remaining":%s,"technology":%s,"manufacturer":%s,"model":%s,"serial":%s,"design_capacity_wh":%s,"full_charge_capacity_wh":%s,"health_pct":%s,"cycle_count":%s,"voltage_v":%s,"power_now_w":%s}' \
        "$(jstr "$BNAME")" "$(jstr "$BSTATUS")" "$(jnum "$BCAP")" "$(jstr "$BTECH")" \
        "$(jstr "$BMANUF")" "$(jstr "$BMODEL")" "$(jstr "$BSERIAL")" \
        "$(jnum "$BDESIGN_WH")" "$(jnum "$BFULL_WH")" "${BHEALTH}" "${BCYCLES}" \
        "$(jnum "$BVOLT_V")" "$(jnum "$BPOW_W")")
done

BAT_JSON="[${BAT_JSON}]"

# ============================================================
# 7. NETWORK
# ============================================================
log_section "NETWORK"

NET_JSON=""

for ipath in /sys/class/net/*/; do
    IFACE=$(basename "$ipath")
    [ "$IFACE" = "lo" ] && continue
    ITYPE=$(cat "${ipath}type" 2>/dev/null || echo "0")
    IS_WLAN="false"
    IS_BT="false"
    [ -d "${ipath}wireless" ] || [ -d "${ipath}phy80211" ] && IS_WLAN="true"
    echo "$IFACE" | grep -qiE "^wl" && IS_WLAN="true"
    echo "$IFACE" | grep -qiE "^bt|bluetooth" && IS_BT="true"
    [[ "$ITYPE" =~ ^(1|801|24)$ ]] || [ "$IS_WLAN" = "true" ] || continue

    IMAC=$(cat "${ipath}address" 2>/dev/null || echo "")
    ISPEED=$(cat "${ipath}speed" 2>/dev/null || echo "")
    ISTATE=$(cat "${ipath}operstate" 2>/dev/null || echo "unknown")
    IIP4=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet )[0-9./]+' || echo "")
    IGW=$(ip route show dev "$IFACE" 2>/dev/null | grep "^default" | awk '{print $3}' | head -1 || echo "")
    IDRV=$(readlink -f "${ipath}device/driver" 2>/dev/null | xargs basename 2>/dev/null || echo "")

    ISSID=""
    ISIG=""
    if [ "$IS_WLAN" = "true" ] && cmd iwconfig; then
        ISSID=$(iwconfig "$IFACE" 2>/dev/null | grep -oP 'ESSID:"[^"]*"' | cut -d'"' -f2 || echo "")
        ISIG=$(iwconfig "$IFACE" 2>/dev/null | grep -oP 'Signal level=-?[0-9]+' | grep -oP '-?[0-9]+' || echo "")
    fi

    TYPE_LBL="LAN"
    [ "$IS_WLAN" = "true" ] && TYPE_LBL="WiFi"
    [ "$IS_BT"   = "true" ] && TYPE_LBL="Bluetooth"
    log_ok "NIC [$TYPE_LBL]: $IFACE - $ISTATE - $IMAC"

    [ -n "$NET_JSON" ] && NET_JSON+=","
    NET_JSON+=$(printf '{"name":%s,"mac":%s,"speed_mbps":%s,"state":%s,"is_wireless":%s,"is_bluetooth":%s,"driver":%s,"ip4":%s,"gateway":%s,"ssid":%s,"signal_dbm":%s}' \
        "$(jstr "$IFACE")" "$(jstr "$IMAC")" "$(jnum "${ISPEED:-0}")" "$(jstr "$ISTATE")" \
        "$IS_WLAN" "$IS_BT" "$(jstr "$IDRV")" "$(jstr "$IIP4")" "$(jstr "$IGW")" \
        "$(jstr "$ISSID")" "$(jstr "$ISIG")")
done

NET_JSON="[${NET_JSON}]"

# ============================================================
# 8. AUDIO
# ============================================================
log_section "AUDIO"

AUDIO_JSON=""
if cmd lspci; then
    lspci 2>/dev/null | grep -iE "Audio|Sound|Multimedia" > "$TMPD/audio.txt" || true
    while IFS= read -r line; do
        ASLOT=$(echo "$line" | cut -d' ' -f1)
        ANAME=$(echo "$line" | sed 's/^[^ ]* [^:]*: //')
        ADRV=$(lspci -v -s "$ASLOT" 2>/dev/null | grep "Kernel driver" | sed 's/.*: //' | xargs || echo "")
        log_ok "Audio: $ANAME"
        [ -n "$AUDIO_JSON" ] && AUDIO_JSON+=","
        AUDIO_JSON+=$(printf '{"name":%s,"pci_slot":%s,"driver":%s}' "$(jstr "$ANAME")" "$(jstr "$ASLOT")" "$(jstr "$ADRV")")
    done < "$TMPD/audio.txt"
fi
# ALSA
ALSA_CARDS=$(cat /proc/asound/cards 2>/dev/null | grep -E "^\s*[0-9]" | head -4 || echo "")
echo "$ALSA_CARDS" > "$TMPD/alsa.txt"
while IFS= read -r al; do
    [ -z "$al" ] && continue
    ACNAME=$(echo "$al" | sed 's/.*\]: //' | sed 's/ \[.*//')
    log_info "ALSA: $ACNAME"
done < "$TMPD/alsa.txt"
AUDIO_JSON="[${AUDIO_JSON}]"

# ============================================================
# 9. USB
# ============================================================
log_section "USB"

USB_CTRL_JSON=""
USB_DEV_JSON=""
USB_COUNT=0

if cmd lspci; then
    lspci 2>/dev/null | grep -iE "USB|xHCI|eHCI|oHCI|uHCI" > "$TMPD/usb_ctrl.txt" || true
    while IFS= read -r line; do
        USLOT=$(echo "$line" | cut -d' ' -f1)
        UNAME=$(echo "$line" | sed 's/^[^ ]* [^:]*: //')
        UDRV=$(lspci -v -s "$USLOT" 2>/dev/null | grep "Kernel driver" | sed 's/.*: //' | xargs || echo "")
        log_ok "USB Controller: $UNAME"
        [ -n "$USB_CTRL_JSON" ] && USB_CTRL_JSON+=","
        USB_CTRL_JSON+=$(printf '{"name":%s,"pci_slot":%s,"driver":%s}' "$(jstr "$UNAME")" "$(jstr "$USLOT")" "$(jstr "$UDRV")")
    done < "$TMPD/usb_ctrl.txt"
fi

if cmd lsusb; then
    USB_COUNT=$(lsusb 2>/dev/null | wc -l || echo "0")
    lsusb 2>/dev/null > "$TMPD/lsusb.txt" || true
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        UBUS=$(echo "$line" | grep -oP 'Bus \K[0-9]+')
        UDEV=$(echo "$line" | grep -oP 'Device \K[0-9]+')
        UID2=$(echo "$line" | grep -oP 'ID \K[0-9a-f:]+')
        UDESC=$(echo "$line" | sed 's/.*ID [^ ]* //')
        [ -n "$USB_DEV_JSON" ] && USB_DEV_JSON+=","
        USB_DEV_JSON+=$(printf '{"bus":"%s","device":"%s","id":%s,"name":%s}' "$UBUS" "$UDEV" "$(jstr "$UID2")" "$(jstr "$UDESC")")
    done < "$TMPD/lsusb.txt"
    log_ok "USB devices: $USB_COUNT"
fi

USB_JSON="{\"controllers\":[${USB_CTRL_JSON}],\"connected_count\":${USB_COUNT},\"connected\":[${USB_DEV_JSON}]}"

# ============================================================
# 10. PCIe DEVICES
# ============================================================
log_section "PCIe DEVICES"

PCIE_JSON=""
if cmd lspci; then
    lspci 2>/dev/null > "$TMPD/lspci_all.txt" || true
    while IFS= read -r line; do
        PSLOT=$(echo "$line" | cut -d' ' -f1)
        PNAME=$(echo "$line" | sed 's/^[^ ]* [^:]*: //')
        PPCIID=$(lspci -n -s "$PSLOT" 2>/dev/null | awk '{print $3}' || echo "")
        PDRV=$(lspci -v -s "$PSLOT" 2>/dev/null | grep "Kernel driver" | sed 's/.*: //' | xargs || echo "")
        [ -n "$PCIE_JSON" ] && PCIE_JSON+=","
        PCIE_JSON+=$(printf '{"slot":%s,"name":%s,"pci_id":%s,"driver":%s}' "$(jstr "$PSLOT")" "$(jstr "$PNAME")" "$(jstr "$PPCIID")" "$(jstr "$PDRV")")
    done < "$TMPD/lspci_all.txt"
    PCIE_TOTAL=$(wc -l < "$TMPD/lspci_all.txt" || echo "0")
    log_ok "PCIe devices: $PCIE_TOTAL total"
fi
PCIE_JSON="[${PCIE_JSON}]"

# ============================================================
# 11. THERMALS + FANS + VOLTAGES
# ============================================================
log_section "THERMALS & FANS"

THERMAL_ZONES_JSON=""
FANS_JSON=""
VOLTAGES_JSON=""

for hwmon in /sys/class/hwmon/hwmon*/; do
    HNAME=$(cat "${hwmon}name" 2>/dev/null || echo "unknown")

    # Temperatures
    for tf in "${hwmon}"temp*_input; do
        [ -f "$tf" ] || continue
        TLABEL=$(cat "${tf/_input/_label}" 2>/dev/null || basename "$tf" | sed 's/_input//')
        TRAW=$(cat "$tf" 2>/dev/null || echo "0")
        TC=$(awk -v r="$TRAW" 'BEGIN{printf "%.1f",r/1000}')
        TCRIT="null"
        tcf="${tf/_input/_crit}"
        if [ -f "$tcf" ]; then
            tcraw=$(cat "$tcf" 2>/dev/null || echo "0")
            TCRIT=$(awk -v r="$tcraw" 'BEGIN{printf "%.1f",r/1000}')
        fi

        is_c=$(awk -v t="$TC" 'BEGIN{print (t>90)?1:0}')
        is_h=$(awk -v t="$TC" 'BEGIN{print (t>75)?1:0}')
        if   [ "$is_c" = "1" ]; then log_err  "Thermal: $HNAME/$TLABEL = ${TC}°C CRITICAL"
        elif [ "$is_h" = "1" ]; then log_warn "Thermal: $HNAME/$TLABEL = ${TC}°C HIGH"
        else                         log_ok   "Thermal: $HNAME/$TLABEL = ${TC}°C"
        fi

        [ -n "$THERMAL_ZONES_JSON" ] && THERMAL_ZONES_JSON+=","
        THERMAL_ZONES_JSON+=$(printf '{"source":%s,"label":%s,"temp_c":%s,"crit_c":%s}' "$(jstr "$HNAME")" "$(jstr "$TLABEL")" "$TC" "$TCRIT")
    done

    # Fans
    for ff in "${hwmon}"fan*_input; do
        [ -f "$ff" ] || continue
        FRPM=$(cat "$ff" 2>/dev/null || echo "0")
        FLABEL=$(cat "${ff/_input/_label}" 2>/dev/null || basename "$ff" | sed 's/_input//')
        log_ok "Fan: $HNAME/$FLABEL = ${FRPM} RPM"
        [ -n "$FANS_JSON" ] && FANS_JSON+=","
        FANS_JSON+=$(printf '{"source":%s,"label":%s,"speed_rpm":%s}' "$(jstr "$HNAME")" "$(jstr "$FLABEL")" "$FRPM")
    done

    # Voltages
    for vf in "${hwmon}"in*_input; do
        [ -f "$vf" ] || continue
        VRAW=$(cat "$vf" 2>/dev/null || echo "0")
        VV=$(awk -v r="$VRAW" 'BEGIN{printf "%.3f",r/1000}')
        VLABEL=$(cat "${vf/_input/_label}" 2>/dev/null || basename "$vf" | sed 's/_input//')
        [ -n "$VOLTAGES_JSON" ] && VOLTAGES_JSON+=","
        VOLTAGES_JSON+=$(printf '{"source":%s,"label":%s,"value_v":%s}' "$(jstr "$HNAME")" "$(jstr "$VLABEL")" "$VV")
    done
done

# ACPI thermal zones
for tz in /sys/class/thermal/thermal_zone*/; do
    TZTYPE=$(cat "${tz}type" 2>/dev/null || echo "unknown")
    TZRAW=$(cat "${tz}temp" 2>/dev/null || echo "0")
    TZTC=$(awk -v r="$TZRAW" 'BEGIN{printf "%.1f",r/1000}')
    [ -n "$THERMAL_ZONES_JSON" ] && THERMAL_ZONES_JSON+=","
    THERMAL_ZONES_JSON+=$(printf '{"source":"acpi","label":%s,"temp_c":%s,"crit_c":null}' "$(jstr "$TZTYPE")" "$TZTC")
done

THERMAL_JSON="{\"zones\":[${THERMAL_ZONES_JSON}],\"fans\":[${FANS_JSON}],\"voltages\":[${VOLTAGES_JSON}]}"

# ============================================================
# 12. OPERATING SYSTEM
# ============================================================
log_section "OPERATING SYSTEM"

KERNEL=$(uname -r 2>/dev/null || echo "Unknown")
OS_NAME=$(. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME" || echo "Linux")
OS_ID=$(. /etc/os-release 2>/dev/null && echo "$ID" || echo "linux")
OS_VER=$(. /etc/os-release 2>/dev/null && echo "$VERSION_ID" || echo "")
ARCH=$(uname -m 2>/dev/null || echo "x86_64")
HOSTNAME=$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo "unknown")
UPTIME_SEC=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo "0")
UPTIME_H=$(awk -v s="$UPTIME_SEC" 'BEGIN{printf "%.1f",s/3600}')
LAST_BOOT=$(who -b 2>/dev/null | awk '{print $3,$4}' || date -d "@$(($(date +%s)-UPTIME_SEC))" '+%Y-%m-%d %H:%M' 2>/dev/null || echo "")
SWAP_TOTAL=$(awk '/SwapTotal/{printf "%.1f",$2/1048576}' /proc/meminfo)
SWAP_FREE=$(awk '/SwapFree/{printf "%.1f",$2/1048576}' /proc/meminfo)
INIT_SYS=$(ps -p 1 -o comm= 2>/dev/null || echo "")
TZ=$(timedatectl show 2>/dev/null | grep "^Timezone=" | cut -d= -f2 || cat /etc/timezone 2>/dev/null || echo "")

log_ok "OS: $OS_NAME - Kernel: $KERNEL ($ARCH)"
log_ok "Uptime: ${UPTIME_H}h - Boot: $LAST_BOOT"

OS_JSON=$(printf '{"name":%s,"id":%s,"version":%s,"kernel":%s,"architecture":%s,"hostname":%s,"uptime_hours":%s,"last_boot":%s,"total_ram_gb":%s,"free_ram_gb":%s,"swap_total_gb":%s,"swap_free_gb":%s,"timezone":%s,"init_system":%s}' \
    "$(jstr "$OS_NAME")" "$(jstr "$OS_ID")" "$(jstr "$OS_VER")" "$(jstr "$KERNEL")" \
    "$(jstr "$ARCH")" "$(jstr "$HOSTNAME")" "$(jnum "$UPTIME_H")" "$(jstr "$LAST_BOOT")" \
    "$(jnum "$TOTAL_RAM_GB")" "$(jnum "$FREE_RAM_GB")" "$(jnum "$SWAP_TOTAL")" \
    "$(jnum "$SWAP_FREE")" "$(jstr "$TZ")" "$(jstr "$INIT_SYS")")

# ============================================================
# 13. SECURITY
# ============================================================
log_section "SECURITY"

FW_TYPE="Legacy BIOS"
SECURE_BOOT="false"
[ -d /sys/firmware/efi ] && FW_TYPE="UEFI"

if [ "$FW_TYPE" = "UEFI" ] && cmd mokutil; then
    SBS=$(mokutil --sb-state 2>/dev/null || echo "")
    echo "$SBS" | grep -qi "enabled" && SECURE_BOOT="true"
fi

TPM_PRESENT="false"
TPM_VER=""
if [ -d /sys/class/tpm ]; then
    TPM_PRESENT="true"
    for td in /sys/class/tpm/tpm*/; do
        TPM_VER=$(cat "${td}tpm_version_major" 2>/dev/null || echo "")
        break
    done
    log_ok "TPM v${TPM_VER} detected"
fi

ASLR=$(cat /proc/sys/kernel/randomize_va_space 2>/dev/null || echo "0")
PTRACE=$(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo "")
UFW_ST=$(ufw status 2>/dev/null | head -1 | sed 's/Status: //' || echo "")

log_ok "Firmware: $FW_TYPE - Secure Boot: $SECURE_BOOT"

SECURITY_JSON=$(printf '{"firmware_type":%s,"secure_boot":%s,"tpm_present":%s,"tpm_version":%s,"kernel_aslr":%s,"ptrace_scope":%s,"firewall_ufw":%s}' \
    "$(jstr "$FW_TYPE")" "$(jstr "$SECURE_BOOT")" "$TPM_PRESENT" "$(jstr "$TPM_VER")" \
    "$(jnum "$ASLR")" "$(jstr "$PTRACE")" "$(jstr "$UFW_ST")")

# ============================================================
# 14. PERFORMANCE
# ============================================================
log_section "PERFORMANCE"

read -r LOAD1 LOAD5 LOAD15 _ < /proc/loadavg
log_ok "Load: $LOAD1 / $LOAD5 / $LOAD15"

RAM_TOTAL_P=$(awk '/MemTotal/{printf "%.1f",$2/1048576}' /proc/meminfo)
RAM_FREE_P=$(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo)
RAM_USED_P=$(awk "BEGIN{printf \"%.1f\",$RAM_TOTAL_P - $RAM_FREE_P}")
RAM_PCT_P=$(awk "BEGIN{printf \"%.0f\",($RAM_USED_P/$RAM_TOTAL_P)*100}" 2>/dev/null || echo "0")

VOLS_JSON=""
df -h --output=source,size,used,avail,pcent,target 2>/dev/null | tail -n+2 | grep -vE "^(tmpfs|udev|devtmpfs|none)" > "$TMPD/df.txt" || true
while IFS= read -r vl; do
    [ -z "$vl" ] && continue
    VFS=$(echo "$vl" | awk '{print $1}')
    VSZ=$(echo "$vl" | awk '{print $2}')
    VUS=$(echo "$vl" | awk '{print $3}')
    VAV=$(echo "$vl" | awk '{print $4}')
    VPC=$(echo "$vl" | awk '{print $5}' | tr -d '%')
    VMT=$(echo "$vl" | awk '{print $6}')
    VPC_INT="${VPC%.*}"
    [ "${VPC_INT:-0}" -gt 90 ] 2>/dev/null && log_err  "Disk $VMT: ${VPC}% full - CRITICALLY LOW"
    [ "${VPC_INT:-0}" -gt 80 ] 2>/dev/null && log_warn "Disk $VMT: ${VPC}% full"
    [ -n "$VOLS_JSON" ] && VOLS_JSON+=","
    VOLS_JSON+=$(printf '{"mount":%s,"filesystem":%s,"size":%s,"used":%s,"available":%s,"used_pct":%s}' \
        "$(jstr "$VMT")" "$(jstr "$VFS")" "$(jstr "$VSZ")" "$(jstr "$VUS")" "$(jstr "$VAV")" "$(jnum "$VPC")")
done < "$TMPD/df.txt"

PROC_COUNT=$(ps aux --no-header 2>/dev/null | wc -l || echo "0")

TOP_PROCS_JSON=""
ps aux --no-header 2>/dev/null | sort -rn -k3 | head -10 > "$TMPD/procs.txt" || true
while IFS= read -r pl; do
    [ -z "$pl" ] && continue
    P_PID=$(echo "$pl" | awk '{print $2}')
    PCPU=$(echo "$pl" | awk '{print $3}')
    PMEM=$(echo "$pl" | awk '{print $4}')
    PCMD=$(echo "$pl" | awk '{print $11}')
    [ -n "$TOP_PROCS_JSON" ] && TOP_PROCS_JSON+=","
    TOP_PROCS_JSON+=$(printf '{"pid":%s,"cpu_pct":%s,"mem_pct":%s,"name":%s}' "$(jnum "$P_PID")" "$(jnum "$PCPU")" "$(jnum "$PMEM")" "$(jstr "$PCMD")")
done < "$TMPD/procs.txt"

PERF_JSON=$(printf '{"load_1m":%s,"load_5m":%s,"load_15m":%s,"ram_total_gb":%s,"ram_used_gb":%s,"ram_free_gb":%s,"ram_used_pct":%s,"process_count":%s,"top_processes":[%s],"volumes":[%s]}' \
    "$(jnum "$LOAD1")" "$(jnum "$LOAD5")" "$(jnum "$LOAD15")" \
    "$(jnum "$RAM_TOTAL_P")" "$(jnum "$RAM_USED_P")" "$(jnum "$RAM_FREE_P")" "$(jnum "$RAM_PCT_P")" \
    "$(jnum "$PROC_COUNT")" "$TOP_PROCS_JSON" "$VOLS_JSON")

# ============================================================
# 15. BIOS DEEP
# ============================================================
log_section "BIOS / UEFI"

BIOS_SERIAL=$(dmi "bios-serial" || echo "")
EC_VER=$(dmidecode -t 0 2>/dev/null | grep "EC Firmware" | sed 's/.*Revision: //' | xargs || echo "")

BIOS_DEEP_JSON=$(printf '{"firmware_type":%s,"vendor":%s,"version":%s,"release_date":%s,"board_product":%s,"board_vendor":%s,"board_version":%s,"ec_version":%s}' \
    "$(jstr "$FW_TYPE")" "$(jstr "$BIOS_VENDOR")" "$(jstr "$BIOS_VERSION")" "$(jstr "$BIOS_DATE")" \
    "$(jstr "$BOARD_PRODUCT")" "$(jstr "$BOARD_VENDOR")" "$(jstr "$BOARD_VERSION")" "$(jstr "$EC_VER")")

# ============================================================
# 16. PROBLEM DEVICES (dmesg errors)
# ============================================================
log_section "PROBLEM DEVICES"

PROB_JSON=""
dmesg 2>/dev/null | grep -iE "error|fail|firmware: failed|ACPI Error" | grep -viE "firmware loaded|Calibrat|module" | tail -15 > "$TMPD/dmesg_errs.txt" || true
while IFS= read -r pl; do
    [ -z "$pl" ] && continue
    PMSG=$(echo "$pl" | sed 's/\[.*\] //')
    log_warn "Device issue: $PMSG"
    [ -n "$PROB_JSON" ] && PROB_JSON+=","
    PROB_JSON+=$(printf '{"message":%s,"source":"dmesg"}' "$(jstr "$PMSG")")
done < "$TMPD/dmesg_errs.txt"
[ -z "$PROB_JSON" ] && log_ok "No obvious device errors in dmesg"
PROB_JSON="[${PROB_JSON}]"

# ============================================================
# 17. CHANGE DETECTION (non-stock components)
# ============================================================
log_section "COMPONENT CHANGE DETECTION"

CHANGES_JSON=""

# Mixed RAM vendors
if [ "$USED_SLOTS" -ge 2 ]; then
    RAM_VENDORS=$(echo "$RAM_MODS_JSON" | grep -oP '"manufacturer":"[^"]+"' | sort -u | wc -l)
    if [ "${RAM_VENDORS:-1}" -gt 1 ] 2>/dev/null; then
        log_warn "RAM: Mixed manufacturers detected - possible upgrade"
        CHANGES_JSON+="{\"component\":\"RAM\",\"type\":\"MIXED_VENDOR\",\"severity\":\"info\",\"detail\":\"Multiple RAM manufacturers detected - possible upgrade\"}"
    fi
fi

# Multiple GPUs
GPU_COUNT=$(echo "$GPU_JSON" | grep -o '"name"' | wc -l)
if [ "${GPU_COUNT:-0}" -gt 1 ] 2>/dev/null; then
    [ -n "$CHANGES_JSON" ] && CHANGES_JSON+=","
    log_info "GPU: Multiple adapters - dGPU alongside iGPU"
    CHANGES_JSON+="{\"component\":\"GPU\",\"type\":\"DISCRETE_GPU_PRESENT\",\"severity\":\"info\",\"detail\":\"Multiple GPUs detected\"}"
fi

# NVMe + SATA mix
if echo "$STORAGE_JSON" | grep -q '"transport":"sata"' && echo "$STORAGE_JSON" | grep -q '"transport":"nvme"'; then
    [ -n "$CHANGES_JSON" ] && CHANGES_JSON+=","
    CHANGES_JSON+="{\"component\":\"Storage\",\"type\":\"MIXED_TRANSPORT\",\"severity\":\"info\",\"detail\":\"Both NVMe and SATA storage present\"}"
fi

CHANGE_SUMMARY="No obvious component changes detected"
CHANGES_COUNT=$(echo "$CHANGES_JSON" | grep -o '"component"' | wc -l)
[ "${CHANGES_COUNT:-0}" -gt 0 ] 2>/dev/null && CHANGE_SUMMARY="${CHANGES_COUNT} potential change(s) flagged"
[ "${CHANGES_COUNT:-0}" -gt 0 ] 2>/dev/null && log_warn "$CHANGE_SUMMARY" || log_ok "$CHANGE_SUMMARY"

CHANGE_JSON=$(printf '{"model_id":%s,"changes":[%s],"summary":%s}' "$(jstr "$MODEL_ID")" "$CHANGES_JSON" "$(jstr "$CHANGE_SUMMARY")")

# ============================================================
# 18. SYMPTOM -> HARDWARE DIAGNOSIS
# ============================================================
log_section "SYMPTOM ANALYSIS"

SYMPTOM_DETECTED=""
SYMPTOMS_JSON=""

# Symptom: SMART failure
if echo "$STORAGE_JSON" | grep -q '"smart_failing":true'; then
    log_err "SYMPTOM: Storage failure detected"
    [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
    SYMPTOMS_JSON+='{"symptom":"Storage device failing","severity":"critical","detected_by":"SMART","hardware_component":"Storage","likely_causes":["Failing HDD/SSD - imminent data loss","Bad sectors accumulating","NVMe wear-out"],"immediate_actions":["BACK UP ALL DATA IMMEDIATELY","Replace drive before next boot if possible"],"diagnostic_steps":["Run extended SMART test: smartctl -t long /dev/sdX","Check reallocated sectors count","Clone drive with ddrescue before it dies"]}'
fi

# Symptom: Critical CPU temp
if [ "$CPU_TEMP" != "null" ]; then
    is_crit=$(awk -v t="$CPU_TEMP" 'BEGIN{print (t>90)?1:0}' 2>/dev/null || echo "0")
    is_high=$(awk -v t="$CPU_TEMP" 'BEGIN{print (t>75)?1:0}' 2>/dev/null || echo "0")
    if [ "$is_crit" = "1" ]; then
        log_err "SYMPTOM: CPU temperature critical (${CPU_TEMP}°C)"
        [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
        SYMPTOMS_JSON+=$(printf '{"symptom":"CPU temperature critical (%sC)","severity":"critical","detected_by":"sensors","hardware_component":"CPU / Cooling","likely_causes":["Heatsink clogged with dust","Thermal paste dried out","Heatsink not seated properly","Fan not spinning"],"immediate_actions":["Shut down to prevent permanent damage","Do not run under load"],"diagnostic_steps":["Open laptop and check fan rotation","Clean heatsink fins with compressed air","Replace thermal paste (every 2-3 years)","Reseat heatsink and check screws are tight"]}' "$CPU_TEMP")
    elif [ "$is_high" = "1" ]; then
        log_warn "SYMPTOM: CPU temperature high (${CPU_TEMP}°C)"
        [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
        SYMPTOMS_JSON+=$(printf '{"symptom":"CPU temperature high (%sC)","severity":"warning","detected_by":"sensors","hardware_component":"CPU / Cooling","likely_causes":["Dust buildup in heatsink","Thermal paste degraded","Fan running slowly"],"immediate_actions":["Avoid heavy workloads","Ensure ventilation is not blocked"],"diagnostic_steps":["Clean heatsink with compressed air","Check fan RPM","Consider replacing thermal paste"]}' "$CPU_TEMP")
    fi
fi

# Symptom: Battery critical health
if [ "$IS_LAPTOP" = "true" ]; then
    BHEALTH_CHECK=$(echo "$BAT_JSON" | grep -oP '"health_pct":\K[0-9]+' | head -1 || echo "100")
    if [ "${BHEALTH_CHECK:-100}" -lt 50 ] 2>/dev/null; then
        log_err "SYMPTOM: Battery critically degraded (${BHEALTH_CHECK}%)"
        [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
        SYMPTOMS_JSON+=$(printf '{"symptom":"Battery critically degraded (%s%% health)","severity":"critical","detected_by":"upower","hardware_component":"Battery","likely_causes":["Battery cell degradation - normal after 2-3 years","Battery has been deep-discharged repeatedly","Battery age > 500 charge cycles"],"immediate_actions":["Always use with AC adapter connected","Replace battery as soon as possible"],"diagnostic_steps":["Check cycle count","Order replacement battery by part number","Avoid full discharge/charge cycles until replaced"]}' "$BHEALTH_CHECK")
    elif [ "${BHEALTH_CHECK:-100}" -lt 75 ] 2>/dev/null; then
        log_warn "SYMPTOM: Battery health low (${BHEALTH_CHECK}%)"
        [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
        SYMPTOMS_JSON+=$(printf '{"symptom":"Battery health low (%s%%)","severity":"warning","detected_by":"upower","hardware_component":"Battery","likely_causes":["Normal degradation","High cycle count"],"immediate_actions":["Plan battery replacement"],"diagnostic_steps":["Check cycle count vs manufacturer max","Calibrate battery (full discharge then full charge)"]}' "$BHEALTH_CHECK")
    fi
fi

# Symptom: No RAM in slot (single channel when dual expected)
if [ "$USED_SLOTS" -eq 1 ] && [ "$TOTAL_SLOTS" -ge 2 ]; then
    log_warn "SYMPTOM: Single RAM module in dual-slot system"
    [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
    SYMPTOMS_JSON+='{"symptom":"Single RAM module - dual-channel slot empty","severity":"warning","detected_by":"dmidecode","hardware_component":"RAM","likely_causes":["Second slot always empty (stock config)","RAM module removed/failed","Slot damaged"],"immediate_actions":["Reseat RAM in slot A","Test with RAM in slot B instead"],"diagnostic_steps":["Check if slot B is physically damaged","Try RAM in each slot individually","Add matching RAM for dual-channel (+35% memory bandwidth)"]}'
fi

# Symptom: CPU throttling
if [ "$CPU_FREQ_RATIO" != "null" ] && [ "${CPU_FREQ_RATIO:-100}" -lt 50 ] 2>/dev/null; then
    log_warn "SYMPTOM: CPU running at ${CPU_FREQ_RATIO}% of max frequency - throttling"
    [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
    SYMPTOMS_JSON+=$(printf '{"symptom":"CPU throttling - running at %s%% of max speed","severity":"warning","detected_by":"cpufreq","hardware_component":"CPU / Power","likely_causes":["Thermal throttling due to overheating","Power limit throttling (underpowered adapter)","BIOS power limit settings"],"immediate_actions":["Check CPU temperature","Check AC adapter wattage"],"diagnostic_steps":["Clean cooling system","Check BIOS power settings","Verify correct AC adapter wattage for this model"]}' "$CPU_FREQ_RATIO")
fi

# Symptom: High RAM usage
if [ "${RAM_PCT:-0}" -gt 90 ] 2>/dev/null; then
    log_err "SYMPTOM: RAM usage critical (${RAM_PCT}%)"
    [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
    SYMPTOMS_JSON+=$(printf '{"symptom":"RAM usage critical (%s%%)","severity":"critical","detected_by":"meminfo","hardware_component":"RAM","likely_causes":["Insufficient RAM for workload","Memory leak in running process","RAM module not detected"],"immediate_actions":["Close unnecessary applications","Check if expected RAM total matches installed"],"diagnostic_steps":["Compare detected RAM vs expected","Run memtest86 for hardware faults","Check dmesg for memory errors"]}' "$RAM_PCT")
fi

# Symptom: dmesg errors
DMESG_ERR_COUNT=$(echo "$PROB_JSON" | grep -o '"message"' | wc -l)
if [ "${DMESG_ERR_COUNT:-0}" -gt 3 ] 2>/dev/null; then
    log_warn "SYMPTOM: Multiple device errors in kernel log ($DMESG_ERR_COUNT errors)"
    [ -n "$SYMPTOMS_JSON" ] && SYMPTOMS_JSON+=","
    SYMPTOMS_JSON+=$(printf '{"symptom":"Multiple kernel device errors (%s)","severity":"warning","detected_by":"dmesg","hardware_component":"Various","likely_causes":["Driver issues","Failing hardware","Firmware incompatibility"],"immediate_actions":["Review error messages in Problem Devices section"],"diagnostic_steps":["Run: dmesg | grep -iE error","Update drivers/firmware","Test hardware individually"]}' "$DMESG_ERR_COUNT")
fi

SYMPTOMS_JSON="[${SYMPTOMS_JSON}]"
SYMPTOM_COUNT=$(echo "$SYMPTOMS_JSON" | grep -o '"symptom"' | wc -l)
log_info "Symptoms detected: $SYMPTOM_COUNT"

# ============================================================
# 19. DIAGNOSTIC SUMMARY + HEALTH SCORE
# ============================================================
log_section "DIAGNOSTIC SUMMARY"

HEALTH=100
ISSUES_JSON=""
WARNS_JSON=""

# Deduct points
echo "$STORAGE_JSON" | grep -q '"smart_failing":true' && \
    { HEALTH=$((HEALTH-30)); [ -n "$ISSUES_JSON" ] && ISSUES_JSON+=","; ISSUES_JSON+='"STORAGE FAILING - BACK UP IMMEDIATELY"'; }

if [ "$CPU_TEMP" != "null" ]; then
    awk -v t="$CPU_TEMP" 'BEGIN{exit !(t>90)}' && \
        { HEALTH=$((HEALTH-20)); [ -n "$ISSUES_JSON" ] && ISSUES_JSON+=","; ISSUES_JSON+="\"CPU CRITICAL: ${CPU_TEMP}°C\""; }
    awk -v t="$CPU_TEMP" 'BEGIN{exit !(t>75 && t<=90)}' && \
        { HEALTH=$((HEALTH-10)); [ -n "$WARNS_JSON" ] && WARNS_JSON+=","; WARNS_JSON+="\"CPU temperature high: ${CPU_TEMP}°C\""; }
fi

BHEALTH_F=$(echo "$BAT_JSON" | grep -oP '"health_pct":\K[0-9]+' | head -1 || echo "100")
[ "${BHEALTH_F:-100}" -lt 50 ] 2>/dev/null && \
    { HEALTH=$((HEALTH-20)); [ -n "$ISSUES_JSON" ] && ISSUES_JSON+=","; ISSUES_JSON+="\"Battery critically degraded: ${BHEALTH_F}%\""; }
[ "${BHEALTH_F:-100}" -ge 50 ] 2>/dev/null && [ "${BHEALTH_F:-100}" -lt 75 ] 2>/dev/null && \
    { HEALTH=$((HEALTH-10)); [ -n "$WARNS_JSON" ] && WARNS_JSON+=","; WARNS_JSON+="\"Battery health low: ${BHEALTH_F}%\""; }

[ "${RAM_PCT:-0}" -gt 90 ] 2>/dev/null && \
    { HEALTH=$((HEALTH-10)); [ -n "$WARNS_JSON" ] && WARNS_JSON+=","; WARNS_JSON+="\"RAM usage critical: ${RAM_PCT}%\""; }

DMESG_EC=$(echo "$PROB_JSON" | grep -o '"message"' | wc -l)
[ "${DMESG_EC:-0}" -gt 5 ] 2>/dev/null && HEALTH=$((HEALTH-10))

[ "$HEALTH" -lt 0 ]   && HEALTH=0
[ "$HEALTH" -gt 100 ] && HEALTH=100

if   [ "$HEALTH" -ge 80 ]; then HEALTH_LABEL="GOOD"
elif [ "$HEALTH" -ge 60 ]; then HEALTH_LABEL="FAIR"
elif [ "$HEALTH" -ge 40 ]; then HEALTH_LABEL="POOR"
else                             HEALTH_LABEL="CRITICAL"; fi

ISSUES_COUNT=$(echo "[$ISSUES_JSON]" | grep -o '"' | wc -l | awk '{print int($1/2)}')
WARNS_COUNT=$(echo "[$WARNS_JSON]" | grep -o '"' | wc -l | awk '{print int($1/2)}')

RECOMMENDATION="System appears healthy. Continue routine monitoring."
[ "${ISSUES_COUNT:-0}" -gt 0 ] 2>/dev/null && \
    RECOMMENDATION=$(echo "[$ISSUES_JSON]" | grep -oP '"[^"]+"' | head -1 | tr -d '"' | sed 's/^/Immediate attention: /')
[ "${WARNS_COUNT:-0}" -gt 0 ] 2>/dev/null && [ "${ISSUES_COUNT:-0}" -eq 0 ] && \
    RECOMMENDATION=$(echo "[$WARNS_JSON]" | grep -oP '"[^"]+"' | head -1 | tr -d '"' | sed 's/^/Monitor: /')

SCORE_C="$G"; [ "$HEALTH" -lt 80 ] && SCORE_C="$Y"; [ "$HEALTH" -lt 60 ] && SCORE_C="$R"
printf "\n  ${D}─────────────────────────────────────────────────────${N}\n"
printf   "  ${W}HEALTH SCORE: ${SCORE_C}%d/100 [%s]${N}\n\n" "$HEALTH" "$HEALTH_LABEL"

DIAG_JSON=$(printf '{"health_score":%s,"health_label":%s,"issues_count":%s,"warnings_count":%s,"issues":[%s],"warnings":[%s],"platine_recommendation":%s}' \
    "$HEALTH" "$(jstr "$HEALTH_LABEL")" "${ISSUES_COUNT:-0}" "${WARNS_COUNT:-0}" \
    "$ISSUES_JSON" "$WARNS_JSON" "$(jstr "$RECOMMENDATION")")

# ============================================================
# 20. PLATINE MAP COMPONENTS (for platine-v5.html)
# ============================================================
log_section "GENERATING PLATINE MAP"

MAP_COMPONENTS=""

# CPU
CPU_STATUS="ok"
[ "$CPU_TEMP" != "null" ] && awk -v t="$CPU_TEMP" 'BEGIN{exit !(t>90)}' && CPU_STATUS="err"
[ "$CPU_TEMP" != "null" ] && awk -v t="$CPU_TEMP" 'BEGIN{exit !(t>75 && t<=90)}' && CPU_STATUS="warn"
MAP_COMPONENTS+=$(printf '{"id":"cpu_0","type":"cpu","name":%s,"ref":%s,"zone":"cpu_soc","status":%s,"live_temp_c":%s,"live_load_pct":%s,"specs":{"cores":%s,"threads":%s,"base_mhz":%s,"arch":%s,"stepping":%s}}' \
    "$(jstr "$CPU_MODEL")" "$(jstr "${CPU_CORES}C/${CPU_LOGICAL}T @ ${CPU_MAX_MHZ}MHz")" "$(jstr "$CPU_STATUS")" \
    "$CPU_TEMP" "$(jnum "$CPU_LOAD")" "$(jnum "$CPU_CORES")" "$(jnum "$CPU_LOGICAL")" \
    "$(jnum "$CPU_MAX_MHZ")" "$(jstr "$CPU_ARCH")" "$(jstr "$CPU_STEPPING")")

# RAM modules
SLOT_IDX=0
if [ -n "$RAM_MODS_JSON" ]; then
    echo "[${RAM_MODS_JSON}]" | grep -oP '\{[^}]+\}' > "$TMPD/ram_mods.txt" || true
    while IFS= read -r rm; do
        [ -z "$rm" ] && continue
        RM_SLOT=$(echo "$rm" | grep -oP '"slot":"[^"]+"' | cut -d'"' -f4)
        RM_SIZE=$(echo "$rm" | grep -oP '"size_gb":[0-9.]+' | cut -d: -f2)
        RM_TYPE=$(echo "$rm" | grep -oP '"type":"[^"]+"' | cut -d'"' -f4)
        RM_SPD=$(echo "$rm"  | grep -oP '"speed_mhz":[0-9]+' | cut -d: -f2)
        [ -n "$MAP_COMPONENTS" ] && MAP_COMPONENTS+=","
        MAP_COMPONENTS+=$(printf '{"id":"ram_%s","type":"ram","name":%s,"ref":%s,"zone":"memory_storage","status":"ok","specs":{"size_gb":%s,"type":%s,"speed_mhz":%s,"slot":%s}}' \
            "$SLOT_IDX" "$(jstr "RAM $RM_SLOT")" "$(jstr "${RM_SIZE}GB $RM_TYPE ${RM_SPD}MHz")" \
            "$(jnum "$RM_SIZE")" "$(jstr "$RM_TYPE")" "$(jnum "$RM_SPD")" "$(jstr "$RM_SLOT")")
        SLOT_IDX=$((SLOT_IDX+1))
    done < "$TMPD/ram_mods.txt"
fi

# Storage
DISK_IDX=0
echo "$STORAGE_JSON" | grep -oP '\{[^{}]*"device"[^{}]*\}' > "$TMPD/map_disks.txt" || true
while IFS= read -r disk; do
    [ -z "$disk" ] && continue
    DMODEL=$(echo "$disk" | grep -oP '"model":"[^"]+"' | cut -d'"' -f4)
    DSZ=$(echo "$disk" | grep -oP '"size_gb":[0-9.]+' | cut -d: -f2)
    DTRANS=$(echo "$disk" | grep -oP '"transport":"[^"]+"' | cut -d'"' -f4)
    DFAIL=$(echo "$disk" | grep -oP '"smart_failing":(true|false)' | cut -d: -f2)
    DST="ok"; [ "$DFAIL" = "true" ] && DST="err"
    [ -n "$MAP_COMPONENTS" ] && MAP_COMPONENTS+=","
    MAP_COMPONENTS+=$(printf '{"id":"storage_%s","type":"storage","name":%s,"ref":%s,"zone":"memory_storage","status":%s,"smart_failing":%s}' \
        "$DISK_IDX" "$(jstr "$DMODEL")" "$(jstr "${DSZ}GB $DTRANS")" "$(jstr "$DST")" "${DFAIL:-false}")
    DISK_IDX=$((DISK_IDX+1))
done < "$TMPD/map_disks.txt"

# GPUs
GPU_IDX=0
echo "$GPU_JSON" | grep -oP '\{[^{}]*"name"[^{}]*\}' > "$TMPD/map_gpus.txt" || true
while IFS= read -r gpu; do
    [ -z "$gpu" ] && continue
    GNAME2=$(echo "$gpu" | grep -oP '"name":"[^"]+"' | head -1 | cut -d'"' -f4)
    GVRAM2=$(echo "$gpu" | grep -oP '"vram_mb":[0-9]+' | cut -d: -f2 || echo "null")
    GIGPU=$(echo "$gpu" | grep -oP '"is_integrated":(true|false)' | cut -d: -f2)
    [ -n "$MAP_COMPONENTS" ] && MAP_COMPONENTS+=","
    MAP_COMPONENTS+=$(printf '{"id":"gpu_%s","type":"gpu","name":%s,"ref":%s,"zone":"cpu_soc","status":"ok","is_integrated":%s}' \
        "$GPU_IDX" "$(jstr "$GNAME2")" "$(jstr "VRAM: ${GVRAM2}MB")" "${GIGPU:-false}")
    GPU_IDX=$((GPU_IDX+1))
done < "$TMPD/map_gpus.txt"

# Battery
if [ "$IS_LAPTOP" = "true" ] && [ -n "$BAT_JSON" ]; then
    BH2=$(echo "$BAT_JSON" | grep -oP '"health_pct":\K[0-9]+' | head -1 || echo "100")
    BST="ok"; [ "${BH2:-100}" -lt 50 ] 2>/dev/null && BST="err"; [ "${BH2:-100}" -lt 75 ] 2>/dev/null && [ "${BH2:-100}" -ge 50 ] 2>/dev/null && BST="warn"
    BCAP2=$(echo "$BAT_JSON" | grep -oP '"charge_remaining":\K[0-9]+' | head -1 || echo "0")
    [ -n "$MAP_COMPONENTS" ] && MAP_COMPONENTS+=","
    MAP_COMPONENTS+=$(printf '{"id":"battery_0","type":"battery","name":"Battery","ref":%s,"zone":"power","status":%s,"specs":{"health_pct":%s,"charge_pct":%s}}' \
        "$(jstr "Health: ${BH2}% - Charge: ${BCAP2}%")" "$(jstr "$BST")" "${BH2}" "${BCAP2}")
fi

# Network adapters
NET_IDX=0
echo "$NET_JSON" | grep -oP '\{[^{}]*"name"[^{}]*\}' > "$TMPD/map_nets.txt" || true
while IFS= read -r nic; do
    [ -z "$nic" ] && continue
    NNAME2=$(echo "$nic" | grep -oP '"name":"[^"]+"' | head -1 | cut -d'"' -f4)
    NWLAN=$(echo "$nic" | grep -oP '"is_wireless":(true|false)' | cut -d: -f2)
    NBT=$(echo "$nic" | grep -oP '"is_bluetooth":(true|false)' | cut -d: -f2)
    NTYPE="ethernet"; [ "$NWLAN" = "true" ] && NTYPE="wifi"; [ "$NBT" = "true" ] && NTYPE="bluetooth"
    NSTATE=$(echo "$nic" | grep -oP '"state":"[^"]+"' | cut -d'"' -f4)
    NST="ok"; [ "$NSTATE" = "down" ] && NST="warn"
    [ -n "$MAP_COMPONENTS" ] && MAP_COMPONENTS+=","
    MAP_COMPONENTS+=$(printf '{"id":"net_%s","type":%s,"name":%s,"ref":%s,"zone":"io","status":%s}' \
        "$NET_IDX" "$(jstr "$NTYPE")" "$(jstr "$NNAME2")" "$(jstr "$NSTATE")" "$(jstr "$NST")")
    NET_IDX=$((NET_IDX+1))
done < "$TMPD/map_nets.txt"

# Audio
if [ -n "$AUDIO_JSON" ] && [ "$AUDIO_JSON" != "[]" ]; then
    ANAME2=$(echo "$AUDIO_JSON" | grep -oP '"name":"[^"]+"' | head -1 | cut -d'"' -f4)
    [ -n "$MAP_COMPONENTS" ] && MAP_COMPONENTS+=","
    MAP_COMPONENTS+=$(printf '{"id":"audio_0","type":"audio","name":%s,"ref":"Audio Codec","zone":"display_audio","status":"ok"}' "$(jstr "$ANAME2")")
fi

COMPONENT_COUNT=$(echo "[$MAP_COMPONENTS]" | grep -o '"id"' | wc -l)
log_ok "Platine map generated: $COMPONENT_COUNT components"

# ============================================================
# 21. ASSEMBLE FINAL JSON
# ============================================================
log_section "EXPORTING"

SAFE_MODEL=$(printf '%s_%s' "$MANUFACTURER" "$MODEL" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/_/g' | cut -c1-40)
DATESTAMP=$(date '+%Y%m%d_%H%M%S')
OUTFILE="${OUTPUT_DIR}/platine-scan_${SAFE_MODEL}_${DATESTAMP}.json"

{
printf '{\n'
printf '  "platine_version": %s,\n'   "$(jstr "$PLATINE_VERSION")"
printf '  "scan_id": %s,\n'           "$(jstr "$SCAN_ID")"
printf '  "scan_date": %s,\n'         "$(jstr "$SCAN_DATE")"
printf '  "scan_type": "full_discovery",\n'
printf '  "scanner": "Platine Live USB (Linux)",\n'
printf '  "machine": {\n'
printf '    "manufacturer": %s,\n'    "$(jstr "$MANUFACTURER")"
printf '    "model": %s,\n'           "$(jstr "$MODEL")"
printf '    "model_version": %s,\n'   "$(jstr "$MODEL_VERSION")"
printf '    "model_id": %s,\n'        "$(jstr "$MODEL_ID")"
printf '    "board_product": %s,\n'   "$(jstr "$BOARD_PRODUCT")"
printf '    "board_vendor": %s,\n'    "$(jstr "$BOARD_VENDOR")"
printf '    "board_version": %s,\n'   "$(jstr "$BOARD_VERSION")"
printf '    "board_serial": %s,\n'    "$(jstr "$BOARD_SERIAL")"
printf '    "system_serial": %s,\n'   "$(jstr "$SYSTEM_SERIAL")"
printf '    "chassis_type": %s,\n'    "$(jstr "$CHASSIS_TYPE")"
printf '    "bios_vendor": %s,\n'     "$(jstr "$BIOS_VENDOR")"
printf '    "bios_version": %s,\n'    "$(jstr "$BIOS_VERSION")"
printf '    "bios_date": %s\n'        "$(jstr "$BIOS_DATE")"
printf '  },\n'
printf '  "cpu": %s,\n'               "$CPU_JSON"
printf '  "memory": %s,\n'            "$MEMORY_JSON"
printf '  "storage": %s,\n'           "$STORAGE_JSON"
printf '  "gpu": %s,\n'               "$GPU_JSON"
printf '  "battery": %s,\n'           "$BAT_JSON"
printf '  "power_source": %s,\n'      "$(jstr "$POWER_SOURCE")"
printf '  "network": %s,\n'           "$NET_JSON"
printf '  "audio": %s,\n'             "$AUDIO_JSON"
printf '  "usb": %s,\n'               "$USB_JSON"
printf '  "pci_devices": %s,\n'       "$PCIE_JSON"
printf '  "thermals": %s,\n'          "$THERMAL_JSON"
printf '  "os": %s,\n'                "$OS_JSON"
printf '  "security": %s,\n'          "$SECURITY_JSON"
printf '  "performance": %s,\n'       "$PERF_JSON"
printf '  "bios_deep": %s,\n'         "$BIOS_DEEP_JSON"
printf '  "problem_devices": %s,\n'   "$PROB_JSON"
printf '  "change_detection": %s,\n'  "$CHANGE_JSON"
printf '  "symptom_analysis": %s,\n'  "$SYMPTOMS_JSON"
printf '  "diagnostic_summary": %s,\n' "$DIAG_JSON"
printf '  "platine_map": {\n'
printf '    "schema_version": "1.0",\n'
printf '    "model_id": %s,\n'        "$(jstr "$MODEL_ID")"
printf '    "manufacturer": %s,\n'    "$(jstr "$MANUFACTURER")"
printf '    "model": %s,\n'           "$(jstr "$MODEL")"
printf '    "scan_id": %s,\n'         "$(jstr "$SCAN_ID")"
printf '    "scan_date": %s,\n'       "$(jstr "$SCAN_DATE")"
printf '    "health_score": %d,\n'    "$HEALTH"
printf '    "health_label": %s,\n'    "$(jstr "$HEALTH_LABEL")"
printf '    "dual_channel": %s,\n'    "$DUAL_CHANNEL"
printf '    "bios_version": %s,\n'    "$(jstr "$BIOS_VERSION")"
printf '    "is_laptop": %s,\n'       "$IS_LAPTOP"
printf '    "components": [%s],\n'    "$MAP_COMPONENTS"
printf '    "issues": [%s],\n'        "$ISSUES_JSON"
printf '    "warnings": [%s],\n'      "$WARNS_JSON"
printf '    "symptoms": %s,\n'        "$SYMPTOMS_JSON"
printf '    "change_detection": %s\n' "$CHANGE_JSON"
printf '  }\n'
printf '}\n'
} > "$OUTFILE"

# Copy to standard locations
cp "$OUTFILE" "$TMPD/platine_live.json"    2>/dev/null || true
cp "$OUTFILE" "/tmp/platine_map.json"       2>/dev/null || true

# jq validation if available
if cmd jq; then
    jq empty "$OUTFILE" 2>/dev/null && log_ok "JSON valid ✓" || log_warn "JSON may have issues"
fi

# ── Send to platine.dev ───────────────────────────────────────
PLATINE_API="https://platine.dev/api/live/start"
LIVE_LINK=""

# Ensure DNS is set before connecting
echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

log_info "Connecting to platine.dev..."

if cmd curl; then
    RESPONSE=$(curl -s -m 15 \
        --dns-servers 8.8.8.8 \
        -X POST "$PLATINE_API" \
        -H "Content-Type: application/json" \
        -d @"$OUTFILE" 2>/dev/null || echo "")
elif cmd wget; then
    RESPONSE=$(wget -q -O- --timeout=15 \
        --post-file="$OUTFILE" \
        --header="Content-Type: application/json" \
        "$PLATINE_API" 2>/dev/null || echo "")
fi

# Extract live link from response (use grep -o for Alpine compatibility)
if [ -n "$RESPONSE" ]; then
    LIVE_LINK=$(echo "$RESPONSE" | grep -o '"live_url":"[^"]*"' | grep -o 'https://[^"]*' || echo "")
fi

# ── Final output ──────────────────────────────────────────────
printf "\n"
printf "  ${G}✓ Scan complete!${N}\n"
printf "\n"

if [ -n "$LIVE_LINK" ]; then
    printf "  ${C}┌─────────────────────────────────────────────────────┐${N}\n"
    printf "  ${C}│  Open on any device:                                │${N}\n"
    printf "  ${C}│                                                     │${N}\n"
    printf "  ${C}│  %-51s│${N}\n" "$LIVE_LINK"
    printf "  ${C}│                                                     │${N}\n"
    printf "  ${C}│  Link expires in 24h                                │${N}\n"
    printf "  ${C}└─────────────────────────────────────────────────────┘${N}\n"
    printf "\n"
    # ── QR code ───────────────────────────────────────────────
    if ! cmd qrencode; then
        apk add --no-cache qrencode 2>/dev/null || true
    fi
    if cmd qrencode; then
        printf "  ${W}Scan with your phone:${N}\n\n"
        qrencode -t ANSIUTF8 -m 2 "$LIVE_LINK"
        printf "\n"
    fi
else
    # No internet — show local file path as fallback
    printf "  ${Y}⚠ Could not connect to platine.dev${N}\n"
    printf "  ${W}No internet connection detected.${N}\n"
    printf "  ${W}Scan saved locally: %s${N}\n" "$OUTFILE"
    printf "\n"
    printf "  ${C}┌─────────────────────────────────────────────────────┐${N}\n"
    printf "  ${C}│  Connect to WiFi and re-run platine-scan.sh         │${N}\n"
    printf "  ${C}│  to get your live platine.dev link.                 │${N}\n"
    printf "  ${C}└─────────────────────────────────────────────────────┘${N}\n"
fi

printf "\n"

# ── Live refresh loop (sends updates every 5s) ────────────────
if [ -n "$LIVE_LINK" ]; then
    PLATINE_UPDATE="https://platine.dev/api/live/update"
    SESSION_ID=$(echo "$RESPONSE" | grep -o '"session_id":"[^"]*"' | grep -o '[^"]*"$' | tr -d '"' || echo "")

    if [ -n "$SESSION_ID" ]; then
        log_info "Sending live updates every 5s... (Ctrl+C to stop)"
        while true; do
            sleep 5

            # Quick thermal refresh
            QT_JSON=""
            for hwm in /sys/class/hwmon/hwmon*/; do
                HQN=$(cat "${hwm}name" 2>/dev/null || echo "hw")
                for qtf in "${hwm}"temp*_input; do
                    [ -f "$qtf" ] || continue
                    QTL=$(cat "${qtf/_input/_label}" 2>/dev/null || basename "$qtf" | sed 's/_input//')
                    QTRAW=$(cat "$qtf" 2>/dev/null || echo "0")
                    QTC=$(awk -v r="$QTRAW" 'BEGIN{printf "%.1f",r/1000}')
                    [ -n "$QT_JSON" ] && QT_JSON="$QT_JSON,"
                    _QT_KEY=$(jstr "$HQN/$QTL")
                    QT_JSON="$QT_JSON\"${_QT_KEY}\":$QTC"
                done
            done

            QLIVE_LOAD=$(top -bn1 2>/dev/null | grep "^%Cpu" | awk '{printf "%.1f",100-$8}' || echo "0")
            QLIVE_RAM=$(awk '/MemAvailable/{printf "%.1f",$2/1048576}' /proc/meminfo || echo "0")
            QLIVE_NOW=$(date '+%Y-%m-%d %H:%M:%S')

            PATCH=$(printf '{"session_id":"%s","thermals":{%s},"cpu_load":%s,"ram_free_gb":%s,"updated_at":"%s"}' \
                "$SESSION_ID" "$QT_JSON" "$QLIVE_LOAD" "$QLIVE_RAM" "$QLIVE_NOW")

            if cmd curl; then
                curl -s -m 5 --dns-servers 8.8.8.8 \
                    -X POST "$PLATINE_UPDATE" \
                    -H "Content-Type: application/json" \
                    -d "$PATCH" >/dev/null 2>&1 || true
            fi
        done
    fi
fi
