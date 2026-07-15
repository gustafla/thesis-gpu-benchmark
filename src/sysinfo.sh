#!/usr/bin/env bash
# Extracts software versions

# Kernel version
KERNEL_VER=$(uname -r | cut -d'-' -f1)

# Mesa version
MESA_VER=$(pacman -Q mesa 2>/dev/null | awk '{print $2}' | sed -e 's/^[0-9]*://' -e 's/-.*//' || echo "Not Found")

# Primary vulkan driver
VK_DRIVER=$(grep -h "library_path" /usr/share/vulkan/icd.d/*.json 2>/dev/null \
    | grep -v "lvp" \
    | head -n 1 \
    | awk -F'"' '{print $4}' \
    | xargs -I {} basename {} .so \
    | sed -e 's/^libvulkan_//' -e 's/^lib//')

[ -z "$VK_DRIVER" ] && VK_DRIVER="Unknown"

# glibc version
GLIBC_VER=$(pacman -Q glibc 2>/dev/null | awk '{print $2}' | cut -d'+' -f1 | cut -d'-' -f1 || echo "Not Found")

# Session compositor
if pgrep -x "sway" > /dev/null; then
    COMPOSITOR="sway"
elif pgrep -x "labwc" > /dev/null; then
    COMPOSITOR="labwc"
else
    COMPOSITOR="Unknown"
fi

# wlroots version
WLROOTS_VER="Not Found"
if [ "$COMPOSITOR" != "Unknown" ]; then
    # Find the shared library the compositor is linked against
    WL_LIB=$(ldd "$(command -v $COMPOSITOR)" 2>/dev/null | grep libwlroots | awk '{print $3}' | head -n 1)
    
    # Query pacman for the package that owns this specific file
    if [ -n "$WL_LIB" ] && [ -f "$WL_LIB" ]; then
        WLROOTS_VER=$(pacman -Qqo "$WL_LIB" 2>/dev/null | xargs pacman -Q | awk '{print $2}' | cut -d'-' -f1)
    fi
fi

# Fallback: if compositor isn't running, just grab the highest installed wlroots version
if [ "$WLROOTS_VER" = "Not Found" ] || [ -z "$WLROOTS_VER" ]; then
    WLROOTS_PKG=$(pacman -Qq | grep -E '^wlroots' | sort -V | tail -n1)
    if [ -n "$WLROOTS_PKG" ]; then
        WLROOTS_VER=$(pacman -Q "$WLROOTS_PKG" | awk '{print $2}' | cut -d'-' -f1)
    fi
fi

# Output as CSV to stdout
echo "Component,Version"
echo "Kernel,$KERNEL_VER"
echo "glibc,$GLIBC_VER"
echo "Mesa,$MESA_VER"
echo "Vulkan Driver,$VK_DRIVER"
echo "wlroots,$WLROOTS_VER"
echo "Compositor,$COMPOSITOR"
