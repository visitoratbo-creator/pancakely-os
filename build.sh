#!/bin/bash
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  echo "Please run as root"
  exit 1
fi

ARCH="${1:-x86_64}"
DIST_NAME="pancakelyOS"
DEBIAN_MIRROR="http://deb.debian.org/debian"
DEBIAN_VERSION="bookworm"
WORK_DIR="/opt/${DIST_NAME}-build"
ROOTFS_DIR="${WORK_DIR}/rootfs"

# Map standard CPU arch to Debian arch names
DEBOOTSTRAP_ARCH="${ARCH}"
if [ "${ARCH}" = "x86_64" ]; then
    DEBOOTSTRAP_ARCH="amd64"
fi

echo "==> Initializing build environment for ${ARCH} (${DEBOOTSTRAP_ARCH})..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

echo "==> Running debootstrap for ${DEBIAN_VERSION}..."
if [ "${ARCH}" = "arm64" ]; then
    if [ ! -f /usr/bin/qemu-aarch64-static ]; then
        echo "ERROR: qemu-user-static not found. Cannot cross-compile ARM64."
        exit 1
    fi
    # Stage 1: Download and extract packages without trying to run ARM binaries
    debootstrap --arch="${DEBOOTSTRAP_ARCH}" --foreign "${DEBIAN_VERSION}" "${ROOTFS_DIR}" "${DEBIAN_MIRROR}"
    
    echo "==> Injecting QEMU emulation for ARM64..."
    cp /usr/bin/qemu-aarch64-static "${ROOTFS_DIR}/usr/bin/"
    
    echo "==> Running debootstrap second stage (configuring packages via QEMU)..."
    chroot "${ROOTFS_DIR}" /debootstrap/debootstrap --second-stage
else
    # Native build: Standard single-stage debootstrap
    debootstrap --arch="${DEBOOTSTRAP_ARCH}" "${DEBIAN_VERSION}" "${ROOTFS_DIR}" "${DEBIAN_MIRROR}"
fi

echo "==> Preparing chroot environment..."
# Keep qemu in rootfs for package configuration scripts during chroot
mount --bind /dev "${ROOTFS_DIR}/dev"
mount --bind /dev/pts "${ROOTFS_DIR}/dev/pts"
mount -t proc proc "${ROOTFS_DIR}/proc"
mount -t sysfs sysfs "${ROOTFS_DIR}/sys"
mount -t tmpfs tmpfs "${ROOTFS_DIR}/tmp"

cat << 'CHROOTEOF' > "${ROOTFS_DIR}/tmp/preseed.sh"
#!/bin/bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LANG=en_US.UTF-8

echo "==> Configuring APT repositories and keys..."
cat > /etc/apt/sources.list << 'EOF'
deb http://deb.debian.org/debian bookworm main contrib non-free-firmware
deb http://deb.debian.org/debian bookworm-updates main contrib non-free-firmware
deb http://security.debian.org/debian-security bookworm-security main contrib non-free-firmware
EOF

# Add Raspberry Pi repository if ARM64
if [ "$(uname -m)" = "aarch64" ]; then
    echo "deb http://archive.raspberrypi.org/debian/ bookworm main" >> /etc/apt/sources.list
    apt-get update || true
    apt-get install -y --no-install-recommends wget gnupg2
    wget -qO- https://archive.raspberrypi.org/debian/pool/main/r/raspberrypi-archive-keyring/raspberrypi-archive-keyring_2021.1.1+rpt1_all.deb > /tmp/rpi-key.deb
    dpkg -i /tmp/rpi-key.deb || true
    rm -f /tmp/rpi-key.deb
fi

echo "==> Updating package lists..."
apt-get update

echo "==> Installing core system utilities..."
apt-get install -y --no-install-recommends \
linux-image-amd64 \
firmware-linux-nonfree \
initramfs-tools \
dbus \
systemd \
systemd-sysv \
sudo \
passwd \
iproute2 \
iputils-ping \
net-tools \
openssh-client \
wget \
ca-certificates \
gnupg2 \
less \
tar \
bzip2 \
xz-utils \
zip \
unzip \
rsync \
file \
pciutils \
usbutils \
lshw \
psmisc \
procps \
htop \
tmux \
screen

if [ "$(uname -m)" = "aarch64" ]; then
    echo "==> Bypassing flash-kernel to prevent chroot failure..."
    if command -v flash-kernel >/dev/null; then
        mv /usr/sbin/flash-kernel /usr/sbin/flash-kernel.bak 2>/dev/null || true
    fi
    echo '#!/bin/true' > /usr/sbin/flash-kernel
    chmod +x /usr/sbin/flash-kernel

    echo "==> Installing ARM64/Raspberry Pi specific kernel and bootloader..."
    mkdir -p /boot/firmware
    apt-get install -y --no-install-recommends \
    raspberrypi-bootloader \
    raspberrypi-kernel \
    linux-image-arm64
fi

echo "==> Installing explicit daily-use utilities..."
apt-get install -y --no-install-recommends \
firefox-esr \
network-manager \
alacritty \
neovim \
git \
curl

echo "==> Installing Kali security infusion tools..."
apt-get install -y --no-install-recommends \
nmap \
wireshark \
aircrack-ng \
hydra \
ncrack

echo "==> Installing Tails infusion and performance toolkits..."
apt-get install -y --no-install-recommends \
tor \
nftables \
secure-delete \
xclip \
zram-tools \
irqbalance

echo "==> Installing Graphical Desktop Environment..."
if [ "$(uname -m)" = "x86_64" ]; then
    # Modern, responsive XFCE Desktop for PC
    apt-get install -y --no-install-recommends \
    xorg \
    lightdm \
    lightdm-gtk-greeter \
    xfce4 \
    xfce4-terminal \
    xfce4-whiskermenu-plugin \
    xfce4-panel-profiles \
    xfce4-notifyd \
    xfce4-taskmanager \
    thunar-archive-plugin \
    mousepad \
    ristretto \
    tumbler \
    fonts-dejavu-core \
    fonts-liberation \
    adwaita-icon-theme-full \
    gtk2-engines-murrine \
    xfce4-screenshooter
else
    # Highly optimized Openbox for old Raspberry Pi
    apt-get install -y --no-install-recommends \
    xorg \
    lightdm \
    lightdm-gtk-greeter \
    openbox \
    obconf \
    tint2 \
    xfce4-terminal \
    pcmanfm \
    lxappearance \
    fonts-dejavu-core \
    fonts-liberation \
    adwaita-icon-theme-full \
    xdotool \
    xinput \
    nitrogen \
    volumeicon-alsa
fi

echo "==> Setting up user accounts and permissions..."
useradd -m -s /bin/bash pancakely
echo "pancakely:pancakely" | chpasswd
usermod -aG sudo,netdev,plugdev,cdrom,audio,video,users pancakely
echo "root:root" | chpasswd

echo "==> Configuring NetworkManager..."
systemctl enable NetworkManager
cat > /etc/NetworkManager/conf.d/10-globally-managed-devices.conf << 'EOF'
[keyfile]
unmanaged-devices=none
EOF

echo "==> Configuring ZRAM..."
cat > /etc/default/zramswap << 'EOF'
ALGO=zstd
PERCENT=50
PRIORITY=100
EOF
systemctl enable zramswap

echo "==> Configuring irqbalance..."
systemctl enable irqbalance

echo "==> Applying Systemd Presets (Disabling heavy daemons)..."
mkdir -p /etc/systemd/system-preset
cat > /etc/systemd/system-preset/99-custom.preset << 'EOF'
disable cups.socket cups.path cups.service
disable bluetooth.service bluetooth-auto-enable.service
disable avahi-daemon.service avahi-daemon.socket
disable ModemManager.service
disable whoopsie.service
disable apport.service
EOF
systemctl preset-all

echo "==> Configuring Tails Infusion: Tor Transparent Proxy..."
cat > /etc/tor/torrc << 'EOF'
DataDirectory /var/lib/tor
PIDFile /run/tor/tor.pid
User debian-tor
Group debian-tor

VirtualAddrNetwork 10.192.0.0/10
AutomapHostsOnResolve 1
TransPort 9040
DNSPort 5353
EOF
systemctl enable tor

echo "==> Configuring Tails Infusion: nftables rules to force Web (80/443) over Tor..."
cat > /etc/nftables.conf << 'EOF'
#!/usr/sbin/nft -f

flush ruleset

table ip filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif lo accept
        ct state established,related accept
        icmp type echo-request limit rate 5/second accept
        tcp dport 22 accept
    }

    chain forward {
        type filter hook forward priority 0; policy drop;
    }

    chain output {
        type filter hook output priority 0; policy accept;
    }
}

table ip nat {
    chain output {
        type nat hook output priority -100; policy accept;
        # Bypass Tor for the debian-tor user itself to prevent loops
        meta skuid debian-tor accept
        # Bypass Tor for local loopback
        oif lo accept
        # Force TCP 80 (HTTP) through Tor TransPort
        tcp dport 80 redirect to 9040
        # Force TCP 443 (HTTPS) through Tor TransPort
        tcp dport 443 redirect to 9040
    }
}
EOF
systemctl enable nftables

echo "==> Configuring Tails Infusion: Clipboard and RAM wipe on shutdown..."
mkdir -p /usr/local/bin
cat > /usr/local/bin/wipe.sh << 'EOF'
#!/bin/bash
# Clear clipboard for all active X11 users
for user_uid_dir in /run/user/*; do
    uid=$(basename "$user_uid_dir")
    display=":0"
    xauth_file="$user_uid_dir/gdm/Xauthority"
    if [ -f "$xauth_file" ]; then
        DISPLAY="$display" XAUTHORITY="$xauth_file" su -s /bin/bash -c "xclip -selection clipboard -i /dev/null 2>/dev/null || true" "$uid" || true
        DISPLAY="$display" XAUTHORITY="$xauth_file" su -s /bin/bash -c "xclip -selection primary -i /dev/null 2>/dev/null || true" "$uid" || true
    fi
done

# Flush filesystem caches to RAM then wipe swap and clear caches
sync
echo 3 > /proc/sys/vm/drop_caches

# Wipe ZRAM swap if active
if command -v zramctl >/dev/null 2>&1; then
    for dev in $(zramctl | awk '{print $1}' | grep -v Name); do
        if [ -b "$dev" ]; then
            swapoff "$dev" 2>/dev/null || true
            # Overwrite ZRAM with zeroes to clear compressed data
            dd if=/dev/zero of="$dev" bs=1M count=$(blockdev --getsize64 "$dev" | awk '{print int($1/1048576)}') status=none || true
        fi
    done
fi

# Force remaining memory clearing if kernel supports it
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null || true
EOF
chmod +x /usr/local/bin/wipe.sh

cat > /etc/systemd/system/sec-wipe.service << 'EOF'
[Unit]
Description=Secure Wipe RAM and Clipboard on Shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target kexec.target
After=final.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/wipe.sh
TimeoutStartSec=30
KillMode=none
StandardOutput=syslog

[Install]
WantedBy=halt.target reboot.target shutdown.target
EOF
systemctl enable sec-wipe.service

echo "==> Configuring LightDM for automatic graphical login..."
cat > /etc/lightdm/lightdm.conf << 'EOF'
[SeatDefaults]
autologin-user=pancakely
autologin-user-timeout=0
greeter-session=lightdm-gtk-greeter
user-session=xfce
EOF

if [ "$(uname -m)" = "aarch64" ]; then
    sed -i 's/user-session=xfce/user-session=openbox/' /etc/lightdm/lightdm.conf
fi

echo "==> Applying Pop!_OS Dark Theme Aesthetics for XFCE (x86_64)..."
if [ "$(uname -m)" = "x86_64" ]; then
    # Force Adwaita Dark globally
    cat > /etc/gtk-3.0/settings.ini << 'EOF'
[Settings]
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=DejaVu Sans 11
gtk-cursor-theme-name=Adwaita
gtk-application-prefer-dark-theme=1
EOF

    cat > /etc/gtk-2.0/gtkrc << 'EOF'
gtk-theme-name="Adwaita-dark"
gtk-icon-theme-name="Adwaita"
gtk-font-name="DejaVu Sans 11"
gtk-cursor-theme-name="Adwaita"
EOF

    # Create a custom XFCE theme mimicking Pop!_OS greys via Xfwm4
    mkdir -p /usr/share/themes/PopDark/xfwm4
    cat > /usr/share/themes/PopDark/xfwm4/themerc << 'EOF'
name=PopDark
description=Custom Dark Theme matching Pop_OS
class=Theme

# Window geometry
border_width=1
title_height=24
title_horizontal_offset=0
title_vertical_offset=0

# Window title colors
active_text_color=#ffffff
inactive_text_color=#999999

# Window border colors
active_border_color=#353535
inactive_border_color=#2b2b2b

# Titlebar background gradients
active_title_bg=#353535
inactive_title_bg=#2b2b2b

# Button layout and colors
button_layout=CMiX
button_offset=0
button_spacing=0
button_width=24
button_height=24

close_button_color=#e95420
maximize_button_color=#353535
minimize_button_color=#353535
menu_button_color=#353535

# Shadows
shadow_delta_x=1
shadow_delta_y=1
shadow_opacity=60
shadow_color=#000000
EOF

    # Set XFCE defaults via xfconf-query replacements for the pancakely user
    mkdir -p /home/pancakely/.config/xfce4/xfconf/xfce-perchannel-xml
    cat > /home/pancakely/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="image-path" type="string" value="/usr/share/backgrounds/xfce/xfce-stripes.png"/>
        <property name="last-image" type="string" value="/usr/share/backgrounds/xfce/xfce-stripes.png"/>
        <property name="image-style" type="int" value="5"/>
      </property>
    </property>
  </property>
</channel>
EOF

    cat > /home/pancakely/.config/xfce4/xfconf/xfce-perchannel-xml/xfwm4.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfwm4" version="1.0">
  <property name="general" type="empty">
    <property name="theme" type="string" value="PopDark"/>
    <property name="placement_ratio" type="int" value="50"/>
    <property name="box_move" type="bool" value="true"/>
    <property name="box_resize" type="bool" value="true"/>
  </property>
</channel>
EOF

    cat > /home/pancakely/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-panel.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="array">
    <value type="int" value="1"/>
    <property name="panel-1" type="empty">
      <property name="position" type="string" value="p=6;x=0;y=0"/>
      <property name="size" type="uint" value="32"/>
      <property name="length" type="uint" value="100"/>
      <property name="position-locked" type="bool" value="true"/>
      <property name="plugin-ids" type="array">
        <value type="int" value="1"/>
        <value type="int" value="2"/>
        <value type="int" value="3"/>
        <value type="int" value="4"/>
        <value type="int" value="5"/>
      </property>
    </property>
  </property>
  <property name="plugins" type="empty">
    <property name="plugin-1" type="string" value="whiskermenu"/>
    <property name="plugin-2" type="string" value="tasklist"/>
    <property name="plugin-3" type="string" value="separator"/>
    <property name="plugin-4" type="string" value="systray"/>
    <property name="plugin-5" type="string" value="clock"/>
  </property>
</channel>
EOF

    # Darken xfce4-terminal
    mkdir -p /home/pancakely/.config/xfce4/terminal
    cat > /home/pancakely/.config/xfce4/terminal/terminalrc << 'EOF'
[Configuration]
ColorForeground=#ffffff
ColorBackground=#2d2d2d
ColorCursor=#ffffff
ColorPalette=#2d2d2d;cc0000;4e9a06;c4a000;3465a4;75507b;06989a;d3d7cf;555753;ef2929;73d216;fce94f;729fcf;ad7fa8;34e2e2;eeeeec
FontName=DejaVu Sans Mono 12
ScrollingBar=TERMINAL_SCROLLBAR_NONE
MiscCursorBlinks=TRUE
EOF

    chown -R pancakely:pancakely /home/pancakely/.config
fi

echo "==> Applying Openbox configuration for Raspberry Pi (arm64)..."
if [ "$(uname -m)" = "aarch64" ]; then
    mkdir -p /home/pancakely/.config/openbox
    cat > /home/pancakely/.config/openbox/rc.xml << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<openbox_config xmlns="http://openbox.org/3.4/rc" xmlns:xi="http://www.w3.org/2001/XInclude">
  <resistance>
    <strength>10</strength>
    <screen_edge_strength>20</screen_edge_strength>
  </resistance>
  <focus>
    <focusNew>yes</focusNew>
    <followMouse>no</followMouse>
    <focusLast>yes</focusLast>
    <underMouse>no</underMouse>
    <unfocusOnLeave>no</unfocusOnLeave>
    <focusOnMap>yes</focusOnMap>
  </focus>
  <placement>
    <policy>Smart</policy>
    <center>yes</center>
  </placement>
  <theme>
    <name>Onyx-Citrus</name>
    <titleLayout>NLIMC</titleLayout>
    <keepBorder>yes</keepBorder>
    <animateIconify>no</animateIconify>
    <font place="ActiveWindow">
      <name>Sans</name>
      <size>10</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
    <font place="InactiveWindow">
      <name>Sans</name>
      <size>10</size>
      <weight>bold</weight>
      <slant>normal</slant>
    </font>
  </theme>
  <desktops>
    <number>1</number>
    <firstdesk>1</firstdesk>
    <names>
      <name>Desktop</name>
    </names>
  </desktops>
  <resize>
    <drawContents>no</drawContents>
    <popupShow>Nonpixel</popupShow>
    <popupPosition>Center</popupPosition>
    <popupFixedPosition>no</popupFixedPosition>
  </resize>
  <margins>
    <top>0</top>
    <bottom>0</bottom>
    <left>0</left>
    <right>0</right>
  </margins>
  <keyboard>
    <keybind key="A-F4">
      <action name="Close"/>
    </keybind>
    <keybind key="A-F10">
      <action name="MaximizeFull"/>
    </keybind>
  </keyboard>
  <mouse>
    <context name="Frame">
      <mousebind button="A-Left" action="Press">
        <action name="Focus"/>
        <action name="Raise"/>
        <action name="Unshade"/>
      </mousebind>
      <mousebind button="A-Left" action="Drag">
        <action name="Move"/>
      </mousebind>
      <mousebind button="A-Right" action="Press">
        <action name="Focus"/>
        <action name="Raise"/>
        <action name="Unshade"/>
      </mousebind>
      <mousebind button="A-Right" action="Drag">
        <action name="Resize"/>
      </mousebind>
    </context>
  </mouse>
  <applications>
    <application name="*">
      <decor>yes</decor>
      <shade>no</shade>
      <maximized>no</maximized>
    </application>
  </applications>
</openbox_config>
EOF

    # Autostart tint2 and pcmanfm for Openbox
    mkdir -p /home/pancakely/.config/openbox/autostart
    cat > /home/pancakely/.config/openbox/autostart/autostart.sh << 'EOF'
#!/bin/bash
# Set dark theme manually for Openbox GTK apps
export GTK_THEME=Adwaita:dark
pcmanfm --desktop &
tint2 &
volumeicon &
EOF
    chmod +x /home/pancakely/.config/openbox/autostart/autostart.sh

    # Minimal dark tint2 config
    mkdir -p /home/pancakely/.config/tint2
    cat > /home/pancakely/.config/tint2/tint2rc << 'EOF'
# Tint2 config for pancakelyOS ARM64
rounded = 0
border_width = 0
background_color = #2d2d2d 100
panel_position = bottom center horizontal
panel_size = 100% 32
panel_margin = 0 0
panel_padding = 0 0 0
font_color = #ffffff 100
taskbar_mode = single_desktop
taskbar_padding = 2 0 2
task_font = Sans 10
task_active_font_color = #ffffff 100
task_background_id = 0
task_active_background_id = 1
task_name = 1
task_maximum_size = 150 32

# Background 0: normal
bg0_rounded = 0
bg0_border_width = 0
bg0_background_color = #2d2d2d 100

# Background 1: active
bg1_rounded = 0
bg1_border_width = 1
bg1_border_color = #e95420 100
bg1_background_color = #353535 100

# Clock
clock_font = Sans 11
clock_color = #ffffff 100
clock_padding = 5 0
clock_lclick_command = zenity --calendar
clock_rclick_command = zenity --calendar
EOF

    chown -R pancakely:pancakely /home/pancakely/.config
fi

echo "==> Configuring Neovim..."
mkdir -p /home/pancakely/.config/nvim
cat > /home/pancakely/.config/nvim/init.vim << 'EOF'
set number
set relativenumber
set tabstop=4
set shiftwidth=4
set expandtab
set autoindent
set smartindent
set mouse=a
set encoding=utf-8
set clipboard=unnamedplus
syntax on
colorscheme desert
EOF
chown -R pancakely:pancakely /home/pancakely/.config/nvim

echo "==> Setting up Alacritty config..."
mkdir -p /home/pancakely/.config/alacritty
cat > /home/pancakely/.config/alacritty/alacritty.yml << 'EOF'
env:
  TERM: xterm-256color

window:
  padding:
    x: 5
    y: 5
  decorations: full

font:
  normal:
    family: DejaVu Sans Mono
    style: Regular
  bold:
    family: DejaVu Sans Mono
    style: Bold
  size: 11.0

colors:
  primary:
    background: '0x2d2d2d'
    foreground: '0xffffff'
  normal:
    black:   '0x2d2d2d'
    red:     '0xcc0000'
    green:   '0x4e9a06'
    yellow:  '0xc4a000'
    blue:    '0x3465a4'
    magenta: '0x75507b'
    cyan:    '0x06989a'
    white:   '0xd3d7cf'
EOF
chown -R pancakely:pancakely /home/pancakely/.config/alacritty

echo "==> Generating initramfs and cleaning up apt cache..."
initramfs-tools -c
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "==> Finalizing chroot..."
CHROOTEOF

chmod +x "${ROOTFS_DIR}/tmp/preseed.sh"
chroot "${ROOTFS_DIR}" /tmp/preseed.sh
rm -f "${ROOTFS_DIR}/tmp/preseed.sh"

echo "==> Unmounting chroot filesystems..."
umount -l "${ROOTFS_DIR}/tmp" || true
umount -l "${ROOTFS_DIR}/sys" || true
umount -l "${ROOTFS_DIR}/proc" || true
umount -l "${ROOTFS_DIR}/dev/pts" || true
umount -l "${ROOTFS_DIR}/dev" || true

# Remove cross-compilation static binaries to save space
rm -f "${ROOTFS_DIR}/usr/bin/qemu-"*"-static"

echo "==> Packaging OS for ${ARCH}..."

if [ "${ARCH}" = "x86_64" ]; then
    echo "==> Building x86_64 Bootable Live ISO..."
    ISO_DIR="${WORK_DIR}/iso"
    LIVE_DIR="${ISO_DIR}/live"
    mkdir -p "${LIVE_DIR}"
    
    echo "Creating SquashFS filesystem..."
    mksquashfs "${ROOTFS_DIR}" "${LIVE_DIR}/filesystem.squashfs" -comp zstd -b 1M -noappend

    echo "Setting up GRUB for UEFI and BIOS boot..."
    mkdir -p "${ISO_DIR}/boot/grub"
    
    cat > "${ISO_DIR}/boot/grub/grub.cfg" << 'EOF'
set default=0
set timeout=5

menuentry "pancakelyOS (x86_64)" {
    linux /live/vmlinuz boot=live components quiet splash
    initrd /live/initrd.img
}
EOF

    cp "${ROOTFS_DIR}/boot/vmlinuz-"* "${ISO_DIR}/live/vmlinuz" 2>/dev/null || cp "${ROOTFS_DIR}/vmlinuz-"* "${ISO_DIR}/live/vmlinuz"
    cp "${ROOTFS_DIR}/boot/initrd.img-"* "${ISO_DIR}/live/initrd.img" 2>/dev/null || cp "${ROOTFS_DIR}/initrd.img-"* "${ISO_DIR}/live/initrd.img"

    # Create EFI boot structure
    mkdir -p "${ISO_DIR}/EFI/BOOT"
    grub-mkimage -O x86_64-efi -o "${ISO_DIR}/EFI/BOOT/BOOTX64.EFI" -p /boot/grub normal iso9660 biosdisk part_msdos part_gpt
    mkdir -p "${ISO_DIR}/boot/grub/x86_64-efi"
    cp /usr/lib/grub/x86_64-efi/*.mod "${ISO_DIR}/boot/grub/x86_64-efi/" || true
    cp /usr/lib/grub/x86_64-efi/*.lst "${ISO_DIR}/boot/grub/x86_64-efi/" || true
    
    # Create BIOS boot structure
    mkdir -p "${ISO_DIR}/boot/grub/i386-pc"
    cp /usr/lib/grub/i386-pc/*.mod "${ISO_DIR}/boot/grub/i386-pc/" || true
    cp /usr/lib/grub/i386-pc/*.lst "${ISO_DIR}/boot/grub/i386-pc/" || true
    cat /usr/lib/grub/i386-pc/cdboot.img > "${ISO_DIR}/boot/grub/bios.img" || true

    echo "Generating ISO with xorriso..."
    xorriso -as mkisofs \
        -r \
        -V "pancakelyOS_x86_64" \
        -partition_offset 16 \
        -o "${WORK_DIR}/pancakelyOS-x86_64.iso" \
        -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
        -b boot/grub/bios.img \
        -no-emul-boot \
        -boot-load-size 4 \
        -boot-info-table \
        --efi-boot boot/grub/efi.img \
        -efi-boot-part --efi-boot-image \
        --protective-msdos-label \
        "${ISO_DIR}"

    echo "==> x86_64 ISO build successful: ${WORK_DIR}/pancakelyOS-x86_64.iso"

elif [ "${ARCH}" = "arm64" ]; then
    echo "==> Building ARM64 Flashable IMG for Raspberry Pi..."
    IMG_FILE="${WORK_DIR}/pancakelyOS-arm64.img"
    IMG_SIZE=4G
    
    # Create blank image
    dd if=/dev/zero of="${IMG_FILE}" bs=1M count=4096 status=progress
    
    # Partition image: 1x 256MB FAT32 (Boot), 1x Rest EXT4 (Root)
    parted -s "${IMG_FILE}" mklabel msdos
    parted -s "${IMG_FILE}" mkpart primary fat32 1MiB 257MiB
    parted -s "${IMG_FILE}" set 1 boot on
    parted -s "${IMG_FILE}" mkpart primary ext4 257MiB 100%

    # Setup loop device
    LOOP_DEV=$(losetup --find --show --partscan "${IMG_FILE}")
    sleep 2

    echo "Formatting partitions..."
    mkfs.vfat -F 32 "${LOOP_DEV}p1"
    mkfs.ext4 -F "${LOOP_DEV}p2"

    # Mount partitions
    MOUNT_DIR="${WORK_DIR}/img_mount"
    mkdir -p "${MOUNT_DIR}/boot" "${MOUNT_DIR}/root"
    mount "${LOOP_DEV}p2" "${MOUNT_DIR}/root"
    mount "${LOOP_DEV}p1" "${MOUNT_DIR}/boot"

    echo "Copying rootfs to image..."
    rsync -aHAX --exclude=/boot/firmware "${ROOTFS_DIR}/" "${MOUNT_DIR}/root/"

    echo "Configuring Raspberry Pi Boot Firmware..."
    # RPi boot files installed to /boot/firmware in Debian
    if [ -d "${MOUNT_DIR}/root/boot/firmware" ]; then
        cp -r "${MOUNT_DIR}/root/boot/firmware/"* "${MOUNT_DIR}/boot/"
    else
        # Fallback to generic boot files
        cp -r "${MOUNT_DIR}/root/boot/"* "${MOUNT_DIR}/boot/"
    fi

    # Ensure cmdline.txt points to the correct root partition
    cat > "${MOUNT_DIR}/boot/cmdline.txt" << 'EOF'
console=serial0,115200 console=tty1 root=PARTUUID=deadbeef-02 rootfstype=ext4 rootwait quiet splash
EOF

    # Extract actual PARTUUID for root partition and replace placeholder
    REAL_PARTUUID=$(blkid -s PARTUUID -o value "${LOOP_DEV}p2")
    sed -i "s/deadbeef-02/${REAL_PARTUUID}/g" "${MOUNT_DIR}/boot/cmdline.txt"

    # Write config.txt to ensure proper ARM boot state
    cat > "${MOUNT_DIR}/boot/config.txt" << 'EOF'
# pancakelyOS ARM64 Raspberry Pi Configuration
arm_64bit=1
disable_overscan=1
gpu_mem=128

# Force max performance on older Pi to prevent UI stutter
force_turbo=1
over_voltage=2
arm_freq=1500
core_freq=500

# Audio
dtparam=audio=on

# Disable Bluetooth to save CPU/RAM resources
dtoverlay=disable-bt
EOF

    echo "Unmounting image partitions..."
    umount -l "${MOUNT_DIR}/boot" || true
    umount -l "${MOUNT_DIR}/root" || true
    losetup -d "${LOOP_DEV}" || true

    echo "==> ARM64 IMG build successful: ${IMG_FILE}"
fi

echo "==> Build process completed successfully!"
exit 0
