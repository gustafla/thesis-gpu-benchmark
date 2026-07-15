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
    # Debian splits Mesa; the Vulkan drivers package is the most relevant for this benchmark
    RAW_MESA=$(dpkg-query -W -f='${Version}' mesa-vulkan-drivers 2>/dev/null)
    [ -z "$RAW_MESA" ] && RAW_MESA=$(dpkg-query -W -f='${Version}' libglx-mesa0 2>/dev/null)
fi
MESA_VER=$(clean_ver "$RAW_MESA")
[ -z "$MESA_VER" ] && MESA_VER="Not Found"

# Primary Vulkan driver
VK_DRIVER=$(grep -h "library_path" /usr/share/vulkan/icd.d/*.json 2>/dev/null \
    | grep -v "lvp" \
    | head -n 1 \
    | awk -F'"' '{print $4}' \
    | xargs -I {} basename {} .so \
    | sed -e 's/^libvulkan_//' -e 's/^lib//')
[ -z "$VK_DRIVER" ] && VK_DRIVER="Unknown"

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

# wlroots version (resolved via dynamic linking to handle multi-version installs)
RAW_WLROOTS=""
if [ "$COMPOSITOR" != "Unknown" ]; then
    WL_LIB=$(ldd "$(command -v $COMPOSITOR)" 2>/dev/null | grep libwlroots | awk '{print $3}' | head -n 1)
    
    if [ -n "$WL_LIB" ] && [ -f "$WL_LIB" ]; then
        if [ "$PM" = "pacman" ]; then
            WLROOTS_PKG=$(pacman -Qqo "$WL_LIB" 2>/dev/null)
            [ -n "$WLROOTS_PKG" ] && RAW_WLROOTS=$(pacman -Q "$WLROOTS_PKG" | awk '{print $2}')
        else
            # dpkg -S searches for the file owner. We use realpath to resolve symlinks which dpkg can choke on.
            WLROOTS_PKG=$(dpkg -S "$(realpath "$WL_LIB")" 2>/dev/null | awk -F: '{print $1}' | head -n 1)
            [ -n "$WLROOTS_PKG" ] && RAW_WLROOTS=$(dpkg-query -W -f='${Version}' "$WLROOTS_PKG" 2>/dev/null)
        fi
    fi
fi

# Fallback if the compositor is dead/missing: grab the highest installed wlroots package
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

# Output as CSV to stdout
echo "Component,Version"
echo "Kernel,$KERNEL_VER"
echo "glibc,$GLIBC_VER"
echo "Mesa,$MESA_VER"
echo "Vulkan Driver,$VK_DRIVER"
echo "wlroots,$WLROOTS_VER"
echo "Compositor,$COMPOSITOR"
