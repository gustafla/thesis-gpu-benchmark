#!/usr/bin/env bash
# Extracts clean software version numbers.
# Supports both Arch Linux (pacman) and Debian/Raspberry Pi OS (apt/dpkg).

# Detect package manager
if command -v pacman >/dev/null 2>&1; then
    PM="pacman"
elif command -v dpkg >/dev/null 2>&1; then
    PM="dpkg"
else
    echo "Error: Neither pacman nor dpkg found."
    exit 1
fi

# Helper function to clean package versions (strips epochs, releases, git hashes, and PPA strings)
clean_ver() {
    echo "$1" | sed -e 's/^[0-9]*://' -e 's/-.*//' -e 's/+.*//' -e 's/~.*//'
}

# Kernel version
KERNEL_VER=$(uname -r | cut -d'-' -f1)

# Mesa version
if [ "$PM" = "pacman" ]; then
    RAW_MESA=$(pacman -Q mesa 2>/dev/null | awk '{print $2}')
else
    RAW_MESA=$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null)
    [ -z "$RAW_MESA" ] && RAW_MESA=$(dpkg-query -W -f='${Version}' libglx-mesa0 2>/dev/null)
fi
MESA_VER=$(clean_ver "$RAW_MESA")
[ -z "$MESA_VER" ] && MESA_VER="Not Found"

# Usermode driver (UMD)
RAW_VK=$(grep -h "library_path" /usr/share/vulkan/icd.d/*.json 2>/dev/null \
    | grep -v "lvp" \
    | head -n 1 \
    | awk -F'"' '{print $4}' \
    | xargs -I {} basename {} .so \
    | sed -e 's/^libvulkan_//' -e 's/^lib//')

# Map Mesa's internal filenames to their recognized upstream project names
case "$RAW_VK" in
    radeon)        UMD="RADV" ;;
    broadcom)      UMD="V3DV" ;;
    panfrost)      UMD="PanVK" ;;
    *)             UMD="$RAW_VK" ;;
esac
[ -z "$UMD" ] && UMD="Unknown"

# Kernelmode driver (KMD)
KMD=""
# Traverse DRM devices to find the primary hardware GPU driver
for card in /sys/class/drm/card[0-9]; do
    if [ -L "$card/device/driver" ]; then
        tmp_kmd=$(basename "$(readlink -f "$card/device/driver")")
        # Ignore virtual displays/software fallback drivers
        if [ "$tmp_kmd" != "vkms" ] && [ "$tmp_kmd" != "dummy" ]; then
            KMD="$tmp_kmd"
            break
        fi
    fi
done
[ -z "$KMD" ] && KMD="Unknown"

# Combine into a transparent identity
VK_DRIVER="${UMD} (${KMD})"

# glibc version
if [ "$PM" = "pacman" ]; then
    RAW_GLIBC=$(pacman -Q glibc 2>/dev/null | awk '{print $2}')
else
    RAW_GLIBC=$(dpkg-query -W -f='${Version}' libc6 2>/dev/null)
fi
GLIBC_VER=$(clean_ver "$RAW_GLIBC")
[ -z "$GLIBC_VER" ] && GLIBC_VER="Not Found"

# Session compositor
if pgrep -x "sway" > /dev/null; then
    COMPOSITOR="sway"
elif pgrep -x "labwc" > /dev/null; then
    COMPOSITOR="labwc"
else
    COMPOSITOR="Unknown"
fi

# Compositor version resolution
COMPOSITOR_VER="Not Found"
if [ "$COMPOSITOR" != "Unknown" ]; then
    if [ "$PM" = "pacman" ]; then
        RAW_COMP_VER=$(pacman -Q "$COMPOSITOR" 2>/dev/null | awk '{print $2}')
    else
        RAW_COMP_VER=$(dpkg-query -W -f='${Version}' "$COMPOSITOR" 2>/dev/null)
    fi
    COMPOSITOR_VER=$(clean_ver "$RAW_COMP_VER")
    [ -z "$COMPOSITOR_VER" ] && COMPOSITOR_VER="Not Found"
fi

# wlroots version (resolved via dynamic linking to handle multi-version installs)
RAW_WLROOTS=""
if [ "$COMPOSITOR" != "Unknown" ]; then
    WL_LIB=$(ldd "$(command -v $COMPOSITOR)" 2>/dev/null | grep libwlroots | awk '{print $3}' | head -n 1)
    
    if [ -n "$WL_LIB" ] && [ -f "$WL_LIB" ]; then
        if [ "$PM" = "pacman" ]; then
            WLROOTS_PKG=$(pacman -Qqo "$WL_LIB" 2>/dev/null)
            [ -n "$WLROOTS_PKG" ] && RAW_WLROOTS=$(pacman -Q "$WLROOTS_PKG" | awk '{print $2}')
        else
            WLROOTS_PKG=$(dpkg -S "$(realpath "$WL_LIB")" 2>/dev/null | awk -F: '{print $1}' | head -n 1)
            [ -n "$WLROOTS_PKG" ] && RAW_WLROOTS=$(dpkg-query -W -f='${Version}' "$WLROOTS_PKG" 2>/dev/null)
        fi
    fi
fi

# Fallback if the compositor is dead/missing
if [ -z "$RAW_WLROOTS" ]; then
    if [ "$PM" = "pacman" ]; then
        WLROOTS_PKG=$(pacman -Qq | grep -E '^wlroots' | sort -V | tail -n1)
        [ -n "$WLROOTS_PKG" ] && RAW_WLROOTS=$(pacman -Q "$WLROOTS_PKG" | awk '{print $2}')
    else
        WLROOTS_PKG=$(dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | grep -E '^(lib)?wlroots' | sort -V | tail -n1)
        [ -n "$WLROOTS_PKG" ] && RAW_WLROOTS=$(dpkg-query -W -f='${Version}' "$WLROOTS_PKG" 2>/dev/null)
    fi
fi

WLROOTS_VER=$(clean_ver "$RAW_WLROOTS")
[ -z "$WLROOTS_VER" ] && WLROOTS_VER="Not Found"

# CPU governor
CPU_GOV=$(cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null | head -n 1)
[ -z "$CPU_GOV" ] && CPU_GOV="Unknown"

# Output as CSV to stdout
echo "Component,Specification"
echo "Linux version,$KERNEL_VER"
echo "glibc version,$GLIBC_VER"
echo "wlroots version,$WLROOTS_VER"
echo "Compositor,$COMPOSITOR $COMPOSITOR_VER"
echo "GPU UMD,Mesa $UMD $MESA_VER"
echo "GPU KMD,$KMD"
echo "CPU Governor,$CPU_GOV"
