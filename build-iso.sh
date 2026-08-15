#!/bin/bash
# ── Platine Live USB — build-iso.sh ────────────────────────────────────────
# Builds a bootable ISO with Alpine Linux + Platine scanner.
# On boot: scans hardware automatically → sends to platine.dev → shows link.
#
# Usage:
#   chmod +x build-iso.sh
#   sudo bash build-iso.sh
#
# Output:
#   platine-live.iso  (flash to USB with Balena Etcher or dd)
#
# Requirements:
#   wget or curl, xorriso or genisoimage
# ───────────────────────────────────────────────────────────────────────────

set -e

PLATINE_VERSION="2.0.0"
ISO_NAME="platine-live.iso"
WORK_DIR="$(mktemp -d /tmp/platine-build-XXXXXX)"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

G='\033[0;32m'; Y='\033[1;33m'; R='\033[0;31m'; C='\033[0;36m'; N='\033[0m'
log_ok()   { printf "  ${G}✓${N} %s\n" "$1"; }
log_info() { printf "  · %s\n" "$1"; }
log_err()  { printf "  ${R}✗ %s${N}\n" "$1"; exit 1; }

echo ""
echo "  ┌─────────────────────────────────────────────────┐"
echo "  │  Platine Live USB — ISO Builder v${PLATINE_VERSION}          │"
echo "  └─────────────────────────────────────────────────┘"
echo ""

# ── Check required files ───────────────────────────────────────────────────
[ -f "$SCRIPT_DIR/platine-scan.sh" ] || log_err "platine-scan.sh not found in $SCRIPT_DIR"
log_ok "platine-scan.sh found"

# ── Check required tools ───────────────────────────────────────────────────
cmd() { command -v "$1" >/dev/null 2>&1; }

if cmd xorriso; then
    ISO_TOOL="xorriso"
elif cmd genisoimage; then
    ISO_TOOL="genisoimage"
elif cmd mkisofs; then
    ISO_TOOL="mkisofs"
else
    log_info "Installing xorriso..."
    apt-get install -y xorriso 2>/dev/null || \
    apk add xorriso 2>/dev/null || \
    log_err "Install xorriso manually: apt install xorriso"
    ISO_TOOL="xorriso"
fi
log_ok "ISO tool: $ISO_TOOL"

# ── Download Alpine Linux ──────────────────────────────────────────────────
ALPINE_VER="3.20.3"
ALPINE_ISO="alpine-standard-${ALPINE_VER}-x86_64.iso"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/x86_64/${ALPINE_ISO}"
ALPINE_SHA256="5a64c23bb0b0a4db41fe2784c617b59b22e8d04af67e6a9b0a56b5dfc9ab6b56"
ALPINE_LOCAL="$WORK_DIR/alpine.iso"

log_info "Downloading Alpine Linux ${ALPINE_VER}..."
if cmd wget; then
    wget -q --show-progress "$ALPINE_URL" -O "$ALPINE_LOCAL"
elif cmd curl; then
    curl -L --progress-bar "$ALPINE_URL" -o "$ALPINE_LOCAL"
else
    log_err "wget or curl required"
fi
if cmd sha256sum && [ -n "$ALPINE_SHA256" ]; then
    echo "${ALPINE_SHA256}  ${ALPINE_LOCAL}" | sha256sum -c - >/dev/null 2>&1 || \
        log_err "Alpine ISO checksum mismatch — download may be corrupted"
fi
log_ok "Alpine downloaded"

# ── Extract Alpine ISO ─────────────────────────────────────────────────────
ISO_ROOT="$WORK_DIR/iso-root"
mkdir -p "$ISO_ROOT"

log_info "Extracting Alpine ISO..."
if cmd xorriso; then
    xorriso -osirrox on -indev "$ALPINE_LOCAL" -extract / "$ISO_ROOT" 2>/dev/null
elif cmd 7z; then
    7z x "$ALPINE_LOCAL" -o"$ISO_ROOT" >/dev/null
else
    MOUNT_DIR="$WORK_DIR/mnt"
    mkdir -p "$MOUNT_DIR"
    mount -o loop,ro "$ALPINE_LOCAL" "$MOUNT_DIR"
    cp -a "$MOUNT_DIR/." "$ISO_ROOT/"
    umount "$MOUNT_DIR"
fi
chmod -R u+w "$ISO_ROOT"
log_ok "Alpine extracted"

# ── Inject Platine files ───────────────────────────────────────────────────
PLATINE_DIR="$ISO_ROOT/platine"
mkdir -p "$PLATINE_DIR"

cp "$SCRIPT_DIR/platine-scan.sh" "$PLATINE_DIR/"
chmod +x "$PLATINE_DIR/platine-scan.sh"

echo "Platine Live USB v${PLATINE_VERSION} — built $(date '+%Y-%m-%d')" > "$PLATINE_DIR/VERSION"

log_ok "Platine files injected"

# ── Fix Alpine repositories ────────────────────────────────────────────────
log_info "Fixing Alpine repositories..."
mkdir -p "$ISO_ROOT/etc/apk"
cat > "$ISO_ROOT/etc/apk/repositories" << 'REPOEOF'
https://dl-cdn.alpinelinux.org/alpine/v3.20/main
https://dl-cdn.alpinelinux.org/alpine/v3.20/community
REPOEOF
log_ok "Repositories fixed"

# ── Pre-download APK packages into ISO ───────────────────────────────────
log_info "Pre-downloading APK packages into ISO..."
APK_CACHE_DIR="$ISO_ROOT/platine/apk-cache"
mkdir -p "$APK_CACHE_DIR"

# Alpine v3.20 x86_64 package index
ALPINE_PKG_BASE="https://dl-cdn.alpinelinux.org/alpine/v3.20"

# Package list: main vs community repo
declare -A PKGS
PKGS=(
    ["bash"]="main"
    ["curl"]="main"
    ["dmidecode"]="main"
    ["smartmontools"]="main"
    ["pciutils"]="main"
    ["usbutils"]="main"
    ["lm-sensors"]="community"
    ["hdparm"]="main"
    ["grep"]="main"
    ["ca-certificates"]="main"
    ["nvme-cli"]="main"
    ["iw"]="main"
    ["wireless-tools"]="main"
    ["qrencode"]="community"
    ["android-tools"]="community"
    ["libimobiledevice"]="community"
)

# Download package index for precise APK filenames
log_info "Fetching Alpine package index..."
for repo in main community; do
    if cmd wget; then
        wget -q --timeout=30 "$ALPINE_PKG_BASE/${repo}/x86_64/APKINDEX.tar.gz" \
            -O "$WORK_DIR/APKINDEX-${repo}.tar.gz" 2>/dev/null || true
    fi
done

get_apk_filename() {
    local pkg="$1" repo="$2"
    local idx="$WORK_DIR/APKINDEX-${repo}.tar.gz"
    [ -f "$idx" ] || return 1
    tar -xzO "$idx" APKINDEX 2>/dev/null | awk -v p="$pkg" '
        BEGIN{RS="\n\n";ORS="\n\n"}
        /^P:/{
            block=$0
            if(block ~ "^P:" p "\n") {
                match(block, /^F:([^\n]+)/, a)
                if(a[1]!="") { print a[1]; exit }
            }
        }' | head -1
}

for pkg in "${!PKGS[@]}"; do
    repo="${PKGS[$pkg]}"
    base="$ALPINE_PKG_BASE/${repo}/x86_64"
    log_info "Downloading $pkg..."
    fname=$(get_apk_filename "$pkg" "$repo" 2>/dev/null || echo "")
    if [ -n "$fname" ]; then
        wget -q --timeout=15 "${base}/${fname}" -O "$APK_CACHE_DIR/${pkg}.apk" 2>/dev/null || true
    else
        # Fallback: scrape directory listing
        PKG_URL=$(wget -q -O- "${base}/?C=N&O=D" 2>/dev/null \
            | grep -o "\"${pkg}-[0-9][^\"]*\.apk\"" | head -1 | tr -d '"' || echo "")
        [ -n "$PKG_URL" ] && \
            wget -q --timeout=15 "${base}/${PKG_URL}" -O "$APK_CACHE_DIR/${pkg}.apk" 2>/dev/null || true
    fi
done

# Write offline installer script
cat > "$ISO_ROOT/platine/install-tools.sh" << 'INSTALLEOF'
#!/bin/sh
# Platine — Install required tools
# Tries offline first, then online

echo "nameserver 8.8.8.8" > /etc/resolv.conf
echo "nameserver 1.1.1.1" >> /etc/resolv.conf

APK_CACHE="/media/usb/platine/apk-cache"

# Setup repos
echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/main" > /etc/apk/repositories
echo "https://dl-cdn.alpinelinux.org/alpine/v3.20/community" >> /etc/apk/repositories

# Check if tools already installed
if command -v bash >/dev/null 2>&1 && command -v dmidecode >/dev/null 2>&1 && command -v nvme >/dev/null 2>&1; then
    echo "Tools already installed"
    exit 0
fi

# Try offline install from USB cache
if ls "$APK_CACHE"/*.apk >/dev/null 2>&1; then
    echo "Installing from USB cache..."
    apk add --no-cache --allow-untrusted "$APK_CACHE"/*.apk 2>/dev/null && exit 0
fi

# Fallback: online install
echo "Installing from internet..."
apk update 2>/dev/null
apk add --no-cache bash curl dmidecode smartmontools pciutils usbutils lm-sensors hdparm grep \
    ca-certificates nvme-cli iw wireless-tools qrencode android-tools libimobiledevice 2>/dev/null
INSTALLEOF
chmod +x "$ISO_ROOT/platine/install-tools.sh"

log_ok "APK packages ready"

# ── Inject WiFi firmware (Realtek rtw88 — common in HP/Dell/Lenovo) ────────
log_info "Downloading Realtek WiFi firmware..."
FIRMWARE_DIR="$ISO_ROOT/lib/firmware/rtlwifi"
mkdir -p "$FIRMWARE_DIR"

FIRMWARE_BASE="https://raw.githubusercontent.com/lwfinger/rtlwifi_new/master"
FIRMWARES="rtl8723defw.bin rtl8723fw.bin rtl8723fw_B.bin"

for fw in $FIRMWARES; do
    if cmd wget; then
        wget -q --timeout=10 "$FIRMWARE_BASE/$fw" -O "$FIRMWARE_DIR/$fw" 2>/dev/null || true
    elif cmd curl; then
        curl -sL --max-time 10 "$FIRMWARE_BASE/$fw" -o "$FIRMWARE_DIR/$fw" 2>/dev/null || true
    fi
done

log_ok "WiFi firmware injected"

# ── Write autorun service with WiFi setup (OpenRC) ─────────────────────────
# Alpine Linux uses OpenRC — we add a service that runs platine-scan.sh on boot

INITD_DIR="$ISO_ROOT/etc/init.d"
mkdir -p "$INITD_DIR"

cat > "$INITD_DIR/platine" << 'SVCEOF'
#!/sbin/openrc-run

description="Platine Hardware Scanner"
pidfile="/run/platine.pid"

depend() {
    after localmount
}

start() {
    ebegin "Starting Platine scanner"

    # Setup DNS
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    echo "nameserver 1.1.1.1" >> /etc/resolv.conf

    # Setup USB tethering if available
    for iface in usb0 eth0 enp0s3; do
        ip link set "$iface" up 2>/dev/null && \
        udhcpc -i "$iface" -t 5 -T 2 -q 2>/dev/null && break || true
    done

    # Load WiFi drivers
    modprobe rtw_8723de 2>/dev/null || true
    modprobe rtw_8822be 2>/dev/null || true

    # Install tools from local cache or internet
    sh /media/usb/platine/install-tools.sh

    # Run scanner
    bash /media/usb/platine/platine-scan.sh
    eend $?
}
SVCEOF
chmod +x "$INITD_DIR/platine"

# Enable service on boot (runlevel default)
RUNLEVEL_DIR="$ISO_ROOT/etc/runlevels/default"
mkdir -p "$RUNLEVEL_DIR"
ln -sf "/etc/init.d/platine" "$RUNLEVEL_DIR/platine"

log_ok "Autorun service configured (OpenRC)"

# ── Write /etc/profile fallback (runs on login if OpenRC fails) ───────────
PROFILE_DIR="$ISO_ROOT/etc/profile.d"
mkdir -p "$PROFILE_DIR"

cat > "$PROFILE_DIR/platine.sh" << 'PROFEOF'
#!/bin/sh
# Platine autorun fallback
if [ ! -f /tmp/platine_done ]; then
    touch /tmp/platine_done
    echo "nameserver 8.8.8.8" > /etc/resolv.conf
    # Setup USB tethering
    ip link set usb0 up 2>/dev/null && udhcpc -i usb0 -t 5 -T 2 -q 2>/dev/null || true
    ip link set eth0 up 2>/dev/null && udhcpc -i eth0 -t 5 -T 2 -q 2>/dev/null || true
    # Install tools
    sh /media/usb/platine/install-tools.sh
    # Run scanner
    bash /media/usb/platine/platine-scan.sh
fi
PROFEOF
chmod +x "$PROFILE_DIR/platine.sh"

log_ok "Login fallback configured"

# ── Build final ISO (Hybrid UEFI + Legacy BIOS) ───────────────────────────
log_info "Building hybrid ISO (UEFI + Legacy BIOS)..."
OUTPUT="$SCRIPT_DIR/$ISO_NAME"

# Install required tools
apt-get install -y xorriso grub-efi-amd64-bin grub-pc-bin mtools 2>/dev/null || true

# Check if Alpine has EFI boot files
EFI_IMG=""
if [ -f "$ISO_ROOT/boot/grub/efi.img" ]; then
    EFI_IMG="$ISO_ROOT/boot/grub/efi.img"
elif [ -f "$ISO_ROOT/efi/boot/bootx64.efi" ]; then
    # Create EFI image from existing EFI files
    mkdir -p "$WORK_DIR/efi"
    dd if=/dev/zero of="$WORK_DIR/efiboot.img" bs=1M count=4 2>/dev/null
    mkfs.vfat "$WORK_DIR/efiboot.img" 2>/dev/null
    mmd -i "$WORK_DIR/efiboot.img" ::/EFI ::/EFI/BOOT 2>/dev/null
    mcopy -i "$WORK_DIR/efiboot.img" "$ISO_ROOT/efi/boot/bootx64.efi" ::/EFI/BOOT/ 2>/dev/null
    EFI_IMG="$WORK_DIR/efiboot.img"
fi

# Build with hybrid boot (UEFI + Legacy)
if [ -n "$EFI_IMG" ] && [ -f "$ISO_ROOT/isolinux/isolinux.bin" ]; then
    log_info "Building with full UEFI + Legacy support..."
    xorriso -as mkisofs \
        -o "$OUTPUT" \
        -V "PLATINE_LIVE" \
        -J -R \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -eltorito-alt-boot \
        -e boot/grub/efi.img \
        -no-emul-boot \
        -isohybrid-gpt-basdat \
        "$ISO_ROOT" 2>/dev/null && \
    isohybrid --uefi "$OUTPUT" 2>/dev/null || \
    xorriso -as mkisofs \
        -o "$OUTPUT" \
        -V "PLATINE_LIVE" \
        -J -R \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "$ISO_ROOT" 2>/dev/null
elif [ -f "$ISO_ROOT/isolinux/isolinux.bin" ]; then
    log_info "Building with Legacy BIOS + isohybrid MBR..."
    xorriso -as mkisofs \
        -o "$OUTPUT" \
        -V "PLATINE_LIVE" \
        -J -R \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        "$ISO_ROOT" 2>/dev/null || \
    xorriso -as mkisofs \
        -o "$OUTPUT" \
        -V "PLATINE_LIVE" \
        -J -R \
        -b isolinux/isolinux.bin \
        -c isolinux/boot.cat \
        -no-emul-boot -boot-load-size 4 -boot-info-table \
        "$ISO_ROOT" 2>/dev/null
else
    log_info "Building basic ISO..."
    xorriso -as mkisofs \
        -o "$OUTPUT" \
        -V "PLATINE_LIVE" \
        -J -R \
        "$ISO_ROOT" 2>/dev/null
fi

log_ok "ISO built"

# ── Cleanup ────────────────────────────────────────────────────────────────
rm -rf "$WORK_DIR"

# ── Done ───────────────────────────────────────────────────────────────────
ISO_MB=$(du -m "$OUTPUT" | cut -f1)
echo ""
echo "  ┌─────────────────────────────────────────────────┐"
printf "  │  ✓ %-47s│\n" "$ISO_NAME ready! (${ISO_MB}MB)"
echo "  │                                                 │"
echo "  │  Flash to USB:                                  │"
echo "  │  · Balena Etcher — easiest (Windows/Mac/Linux)  │"
echo "  │  · dd if=platine-live.iso of=/dev/sdX bs=4M    │"
echo "  │                                                 │"
echo "  │  On boot: connects to platine.dev automatically │"
echo "  └─────────────────────────────────────────────────┘"
echo ""
