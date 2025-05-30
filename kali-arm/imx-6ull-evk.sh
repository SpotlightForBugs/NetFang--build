#!/bin/bash

set -e

# Uncomment to activate debug
# debug=true
if [ "$debug" = true ]; then
    exec > >(tee -a -i "${0%.*}.log") 2>&1
    set -x

fi

# Architecture
architecture=${architecture:-"armhf"}

# Generate a random machine name to be used.
machine=$(dbus-uuidgen)

# Custom hostname variable
hostname=${2:-kali}

# Custom image file name variable - MUST NOT include .img at the end.
imagename=${3:-kali-linux-$1-imx-6ull-evk}

# Suite to use, valid options are:
# kali-rolling, kali-dev, kali-bleeding-edge, kali-dev-only, kali-experimental, kali-last-snapshot
suite=${suite:-"kali-rolling"}

# Free space rootfs in MiB
free_space="300"

# /boot partition in MiB
bootsize="128"

# Select compression, xz or none
compress="xz"

# Choose filesystem format to format ( ext3 or ext4 )
fstype="ext3"

# If you have your own preferred mirrors, set them here.
mirror=${mirror:-"http://http.kali.org/kali"}

# Gitlab URL Kali repository
kaligit="https://gitlab.com/kalilinux"

# Github raw URL
githubraw="https://raw.githubusercontent.com"

# Check EUID=0 you can run any binary as root.
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root or have super user permissions"
    echo "Use: sudo $0 ${1:-2.0} ${2:-kali}"

    exit 1

fi

# Pass version number
if [[ $# -eq 0 ]]; then
    echo "Please pass version number, e.g. $0 2.0, and (if you want) a hostname, default is kali"

    exit 0

fi

# Check exist bsp directory.
if [ ! -e "bsp" ]; then
    echo "Error: missing bsp directory structure"
    echo "Please clone the full repository ${kaligit}/build-scripts/kali-arm"

    exit 255

fi

# Current directory
current_dir="$(pwd)"

# Base directory
basedir=${current_dir}/imx6-"$1"

# Working directory
work_dir="${basedir}/kali-${architecture}"

# Check directory build
if [ -e "${basedir}" ]; then
    echo "${basedir} directory exists, will not continue"

    exit 1

elif [[ ${current_dir} =~ [[:space:]] ]]; then
    echo "The directory "\"${current_dir}"\" contains whitespace. Not supported."

    exit 1

else
    echo "The basedir thinks it is: ${basedir}"
    mkdir -p ${basedir}

fi

components="main,contrib,non-free"

arm="kali-linux-arm ntpdate"

base="apt-transport-https apt-utils bash-completion console-setup dialog \
e2fsprogs ifupdown initramfs-tools inxi iw man-db mlocate net-tools \
netcat-traditional parted pciutils psmisc rfkill screen tmux unrar usbutils \
wget whiptail zerofree"

desktop="kali-desktop-xfce kali-root-login xfonts-terminus xinput \
xserver-xorg-video-fbdev"

tools="kali-linux-default"

services="apache2 atftpd"

extras="alsa-utils bc bison bluez bluez-firmware crda i2c-tools \
kali-linux-core libnss-systemd libssl-dev python3-configobj python3-pip \
python3-requests python3-rpi.gpio python3-smbus triggerhappy"

packages="${arm} ${base} ${services}"

# Automatic configuration to use an http proxy, such as apt-cacher-ng.
# You can turn off automatic settings by uncommenting apt_cacher=off.
# apt_cacher=off
# By default the proxy settings are local, but you can define an external proxy.
# proxy_url="http://external.intranet.local"
apt_cacher=${apt_cacher:-"$(lsof -i :3142 | cut -d ' ' -f3 | uniq | sed '/^\s*$/d')"}

if [ -n "$proxy_url" ]; then
    export http_proxy=$proxy_url

elif [ "$apt_cacher" = "apt-cacher-ng" ]; then
    if [ -z "$proxy_url" ]; then
        proxy_url=${proxy_url:-"http://127.0.0.1:3142/"}
        export http_proxy=$proxy_url

    fi
fi

# Detect architecture
case ${architecture} in
    arm64)
        qemu_bin="/usr/bin/qemu-aarch64-static"
        lib_arch="aarch64-linux-gnu" ;;

    armhf)
        qemu_bin="/usr/bin/qemu-arm-static"
        lib_arch="arm-linux-gnueabihf" ;;

    armel)
        qemu_bin="/usr/bin/qemu-arm-static"
        lib_arch="arm-linux-gnueabi" ;;

esac

# create the rootfs - not much to modify here, except maybe throw in some more packages if you want.
eatmydata debootstrap --foreign \
--keyring=/usr/share/keyrings/kali-archive-keyring.gpg \
--include=kali-archive-keyring,eatmydata \
--components=${components} \
--arch ${architecture} ${suite} ${work_dir} http://http.kali.org/kali

# systemd-nspawn versión
nspawn_ver=$(systemd-nspawn --version | awk '{if(NR==1) print $2}')

# systemd-nspawn enviroment
systemd-nspawn_exec() {
    [[ $nspawn_ver -ge 241 ]] && extra_args="--hostname=$hostname" || true
    [[ $nspawn_ver -ge 245 ]] && extra_args="--console=pipe --hostname=$hostname" || true
    systemd-nspawn -q --bind-ro ${qemu_bin} $extra_args --capability=cap_setfcap -E RUNLEVEL=1,LANG=C -M ${machine} -D ${work_dir} "$@"
}

# We need to manually extract eatmydata to use it for the second stage.
for archive in ${work_dir}/var/cache/apt/archives/*eatmydata*.deb; do
    dpkg-deb --fsys-tarfile "$archive" >${work_dir}/eatmydata
    tar -xkf ${work_dir}/eatmydata -C ${work_dir}
    rm -f ${work_dir}/eatmydata

done

# Prepare dpkg to use eatmydata
systemd-nspawn_exec dpkg-divert --divert /usr/bin/dpkg-eatmydata --rename --add /usr/bin/dpkg

cat >${work_dir}/usr/bin/dpkg <<EOF
#!/bin/sh
if [ -e /usr/lib/${lib_arch}/libeatmydata.so ]; then
    [ -n "\${LD_PRELOAD}" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"

fi

for so in /usr/lib/${lib_arch}/libeatmydata.so; do
    [ -n "\$LD_PRELOAD" ] && LD_PRELOAD="\$LD_PRELOAD:"
    LD_PRELOAD="\$LD_PRELOAD\$so"

done

export LD_PRELOAD
exec "\$0-eatmydata" --force-unsafe-io "\$@"
EOF

chmod 755 ${work_dir}/usr/bin/dpkg

# debootstrap second stage
systemd-nspawn_exec eatmydata /debootstrap/debootstrap --second-stage

cat <<EOF >${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# Set hostname
echo "${hostname}" >${work_dir}/etc/hostname

# So X doesn't complain, we add kali to hosts
cat <<EOF >${work_dir}/etc/hosts
127.0.0.1       localhost
127.0.1.1       ${hostname}
::1             localhost ip6-localhost ip6-loopback
fe00::0         ip6-localnet
ff00::0         ip6-mcastprefix
ff02::1         ip6-allnodes
ff02::2         ip6-allrouters
EOF

# Disable IPv6
cat <<EOF >${work_dir}/etc/modprobe.d/ipv6.conf
# Don't load ipv6 by default
alias net-pf-10 off
EOF

cat <<EOF >${work_dir}/etc/network/interfaces
auto lo
iface lo inet loopback

auto eth0
allow-hotplug eth0
iface eth0 inet dhcp
EOF

# Copy directory bsp into build dir.
cp -rp bsp ${work_dir}

# Workaround for LP: #520465
export MALLOC_CHECK_=0

# Enable the use of http proxy in third-stage in case it is enabled.
if [ -n "$proxy_url" ]; then
    echo "Acquire::http { Proxy \"$proxy_url\" };" >${work_dir}/etc/apt/apt.conf.d/66proxy

fi

# Third stage
cat <<EOF >${work_dir}/third-stage
#!/bin/bash -e
export DEBIAN_FRONTEND=noninteractive

eatmydata apt-get update

eatmydata apt-get -y install git binutils ca-certificates console-common initramfs-tools less locales nano u-boot-tools

echo 'LANG=C.UTF-8' > /etc/default/locale

# Create kali user with kali password... but first, we need to manually make some groups because they don't yet exist...
# This mirrors what we have on a pre-installed VM, until the script works properly to allow end users to set up their own... user.
# However we leave off floppy, because who a) still uses them, and b) attaches them to an SBC!?
# And since a lot of these have serial devices of some sort, dialout is added as well.
# scanner, lpadmin and bluetooth have to be added manually because they don't
# yet exist in /etc/group at this point.
groupadd -r -g 118 bluetooth
groupadd -r -g 113 lpadmin
groupadd -r -g 122 scanner
groupadd -g 1000 kali

useradd -m -u 1000 -g 1000 -G sudo,audio,bluetooth,cdrom,dialout,dip,lpadmin,netdev,plugdev,scanner,video,kali -s /bin/bash kali
echo "kali:kali" | chpasswd

aptops="--allow-change-held-packages -o dpkg::options::=--force-confnew -o Acquire::Retries=3"

# This looks weird, but we do it twice because every so often, there's a failure to download from the mirror
# So to workaround it, we attempt to install them twice.
eatmydata apt-get install -y \$aptops ${packages} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops ${packages} || eatmydata apt-get --yes --fix-broken install
#eatmydata apt-get install -y \$aptops ${desktop} ${extras} ${tools} || eatmydata apt-get --yes --fix-broken install
#eatmydata apt-get install -y \$aptops ${desktop} ${extras} ${tools} || eatmydata apt-get --yes --fix-broken install
eatmydata apt-get install -y \$aptops --autoremove systemd-timesyncd || eatmydata apt-get --yes --fix-broken install

# Linux console/Keyboard configuration
echo 'console-common console-data/keymap/policy select Select keymap from full list' | debconf-set-selections
echo 'console-common console-data/keymap/full select en-latin1-nodeadkeys' | debconf-set-selections

eatmydata apt-get --yes --allow-change-held-packages autoremove

cp -p /bsp/services/all/*.service /etc/systemd/system/

install -m755 /bsp/scripts/rpi-resizerootfs /usr/sbin/

# Regenerated the shared-mime-info database on the first boot
# since it fails to do so properly in a chroot.
systemctl enable smi-hack

# Resize filesystem on first boot
install -m644 /bsp/services/rpi/rpi-resizerootfs.service /etc/systemd/system/
install -m755 /bsp/scripts/rpi-resizerootfs /usr/sbin/
systemctl enable rpi-resizerootfs

# Allow users to use NetworkManager
install -m644 /bsp/polkit/10-networkmanager.rules /etc/polkit-1/rules.d/

cd /root
apt download -o APT::Sandbox::User=root ca-certificates 2>/dev/null

# Copy over the default bashrc
cp /etc/skel/.bashrc /root/.bashrc

# Enable login over serial
echo "T0:23:respawn:/sbin/agetty -L ttyAMA0 115200 vt100" >> /etc/inittab

# Try and make the console a bit nicer
# Set the terminus font for a bit nicer display.
sed -i -e 's/FONTFACE=.*/FONTFACE="Terminus"/' /etc/default/console-setup
sed -i -e 's/FONTSIZE=.*/FONTSIZE="6x12"/' /etc/default/console-setup

# Fix startup time from 5 minutes to 15 secs on raise interface wlan0
sed -i 's/^TimeoutStartSec=5min/TimeoutStartSec=15/g' "/usr/lib/systemd/system/networking.service"

# Clean up dpkg.eatmydata
rm -f /usr/bin/dpkg
dpkg-divert --remove --rename /usr/bin/dpkg
EOF

# Run third stage
chmod 755 ${work_dir}/third-stage
systemd-nspawn_exec /third-stage

# Clean system
systemd-nspawn_exec <<'EOF'
rm -f /0
rm -rf /bsp
fc-cache -frs
rm -rf /tmp/*
rm -rf /etc/*-
rm -rf /hs_err*
rm -rf /third-stage
rm -rf /userland
rm -rf /opt/vc/src
rm -f /etc/ssh/ssh_host_*
rm -rf /var/lib/dpkg/*-old
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*.bin
rm -rf /var/cache/apt/archives/*
rm -rf /var/cache/debconf/*.data-old
for logs in $(find /var/log -type f); do > $logs; done
history -c
EOF

# Define DNS server after last running systemd-nspawn.
echo "nameserver 8.8.8.8" >${work_dir}/etc/resolv.conf

# Disable the use of http proxy in case it is enabled.
if [ -n "$proxy_url" ]; then
    unset http_proxy
    rm -rf ${work_dir}/etc/apt/apt.conf.d/66proxy

fi

# Mirror & suite replacement
if [[ ! -z "${4}" || ! -z "${5}" ]]; then
    mirror=${4}
    suite=${5}

fi

# Define sources.list
cat <<EOF >${work_dir}/etc/apt/sources.list
deb ${mirror} ${suite} ${components//,/ }
#deb-src ${mirror} ${suite} ${components//,/ }
EOF

# # Kernel section. If you want to use a custom kernel, or configuration, replace
# # them in this section.
cat <<EOF >"${work_dir}"/etc/fstab
LABEL=ROOTFS / auto errors=remount-ro 0 1
LABEL=BOOT /boot auto defaults 0 0
EOF

cd ${work_dir}/usr/src
git clone https://github.com/Freescale/linux-fslc.git --depth 1 linux
cd linux
make ARCH=arm KBUILD_DEFCONFIG=imx_v6_v7_defconfig defconfig
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j$(nproc)
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- INSTALL_MOD_PATH=${work_dir} modules_install
cp arch/arm/boot/zImage ${work_dir}/boot
cp arch/arm/boot/dts/*.dtb ${work_dir}/boot
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- mrproper

# Building u-boot
cd ${work_dir}/usr/src
git clone https://github.com/Freescale/u-boot-fslc.git u-boot
cd u-boot
make mx6ull_14x14_evk_defconfig
make -j$(nproc) CROSS_COMPILE=arm-linux-gnueabihf- u-boot.imx
cp u-boot.imx ${work_dir}/boot

cd ${current_dir}
rm -rf ${work_dir}/usr/src

# Calculate the space to create the image.
root_size=$(du -s -B1 ${work_dir} --exclude=${work_dir}/boot | cut -f1)
echo $root_size
root_extra=$((${root_size} / 1024 / 1000 * 5 * 1024 / 5))
echo $root_extra
raw_size=$(($((${free_space} * 1024)) + ${root_extra} + $((${bootsize} * 1024)) + 4096))
echo $raw_size

# Create the disk and partition it
echo "Creating image file ${imagename}.img"
fallocate -l $(echo ${raw_size}Ki | numfmt --from=iec-i --to=si) ${current_dir}/${imagename}.img
echo "Partitioning ${imagename}.img"
parted -s ${current_dir}/${imagename}.img mklabel msdos
parted -s ${current_dir}/${imagename}.img mkpart primary fat32 4MiB ${bootsize}MiB
parted -s -a minimal ${current_dir}/${imagename}.img mkpart primary $fstype ${bootsize}MiB 100%

# Set the partition variables
loopdevice=$(losetup --show -fP "${current_dir}/${imagename}.img")
bootp="${loopdevice}p1"
rootp="${loopdevice}p2"

echo "Writing u-boot"
dd if=${work_dir}/boot/u-boot.imx of=${loopdevice} bs=512 seek=2

# Create file systems
mkfs.vfat -n BOOT -F 32 -v ${bootp}
if [[ $fstype == ext4 ]]; then
    features="-O ^64bit,^metadata_csum"

elif [[ $fstype == ext3 ]]; then
    features="-O ^64bit"

fi

mkfs $features -t $fstype -L ROOTFS ${rootp}

# Create the dirs for the partitions and mount them
mkdir -p ${basedir}/root/
mount ${rootp} ${basedir}/root
mkdir -p ${basedir}/root/boot
mount ${bootp} ${basedir}/root/boot

echo "Rsyncing rootfs into image file"
rsync -HPavz -q --exclude boot ${work_dir}/ ${basedir}/root/
rsync -rtx -q ${work_dir}/boot ${basedir}/root
sync

# Make sure to enable ssh on the device by default
touch "${basedir}"/root/boot/ssh

sync

# Sleep for 10 seconds, to let the cache settle after sync.
sleep 10

# Unmount filesystems
umount -l ${bootp}
umount -l ${rootp}

# Remove loop devices
losetup -d ${loopdevice}

# Limite use cpu function
limit_cpu() {
    # Random name group
    rand=$(
        tr -cd 'A-Za-z0-9' </dev/urandom | head -c4
        echo
    )

    cgcreate -g cpu:/cpulimit-${rand}                # Name of group cpulimit
    cgset -r cpu.shares=800 cpulimit-${rand}         # Max 1024
    cgset -r cpu.cfs_quota_us=80000 cpulimit-${rand} # Max 100000

    # Retry command
    local n=1
    local max=5
    local delay=2

    while true; do
        cgexec -g cpu:cpulimit-${rand} "$@" && break || {
            if [[ $n -lt $max ]]; then
                ((n++))
                echo -e "\e[31m Command failed. Attempt $n/$max \033[0m"

                sleep $delay

            else
                echo "The command has failed after $n attempts."

                break

            fi
        }

    done

    cgdelete -g cpu:/cpulimit-"$rand"
}

if [ $compress = xz ]; then
    if [ $(arch) == 'x86_64' ]; then
        echo "Compressing ${imagename}.img"

        # cpu_cores = Number of cores to use
        [ $(nproc) -lt 3 ] || cpu_cores=3

        # -p Nº cpu cores use
        limit_cpu pixz -p ${cpu_cores:-2} ${current_dir}/${imagename}.img

        chmod 644 ${current_dir}/${imagename}.img.xz

    fi

else
    chmod 644 ${current_dir}/${imagename}.img

fi

# Clean up all the temporary build stuff and remove the directories.
# Comment this out to keep things around if you want to see what may have gone wrong.
echo "Cleaning up the temporary build files..."
rm -rf "${basedir}"
