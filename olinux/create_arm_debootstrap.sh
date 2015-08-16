#!/bin/bash

######################
#    Debootstrap     #
######################

set -e
set -x

show_usage() {
cat <<EOF
# NAME

  $(basename $0) -- Script to create a minimal deboostrap

# OPTIONS

  -d		debian release (wheezy, jessie) 	(default: jessie)
  -b		olinux board (see config_board.sh) 	(default: a20lime)
  -a		add packages to deboostrap
  -n		hostname				(default: olinux)
  -t		target directory for debootstrap	(default: /olinux/debootstrap)
  -y		install yunohost (doesn't work with cross debootstrap)
  -c		cross debootstrap
  -p		use aptcacher proxy
  -i		set path for kernel package or install from testing (set '-i testing' to install from debian testing)
  -e		configure for encrypted partition	(default: false)

EOF
exit 1
}

DEBIAN_RELEASE=jessie
TARGET_DIR=/olinux/debootstrap
DEB_HOSTNAME=olinux
REP=$(dirname $0)
APT='apt-get install -y --force-yes'

while getopts ":a:b:d:n:t:i:ycpe" opt; do
  case $opt in
    d)
      DEBIAN_RELEASE=$OPTARG
      ;;
    b)
      BOARD=$OPTARG
      ;;
    a)
      PACKAGES=$OPTARG
      ;;
    n)
      DEB_HOSTNAME=$OPTARG
      ;;
    t)
      TARGET_DIR=$OPTARG
      ;;
    i)
      INSTALL_KERNEL=$OPTARG
      ;;
    y)
      INSTALL_YUNOHOST=yes
      ;;
    c)
      CROSS=yes
      ;;
    p)
      APTCACHER=yes
      ;;
    e)
      ENCRYPT=yes
      ;;
    \?)
      show_usage
      ;;
  esac
done

. ${REP}/config_board.sh

rm -rf $TARGET_DIR && mkdir -p $TARGET_DIR

chroot_deb (){
  LC_ALL=C LANGUAGE=C LANG=C chroot $1 /bin/bash -c "$2"
}

umount_dir (){
    # Umount proc, sys, and dev
    umount -l "$1"/dev/pts
    umount -l "$1"/dev
    umount -l "$1"/proc
    umount -l "$1"/sys
}

if [ ${CROSS} ] ; then
  # Debootstrap
  mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
  bash ${REP}/script/binfmt-misc-arm.sh unregister
  bash ${REP}/script/binfmt-misc-arm.sh
  debootstrap --arch=armhf --foreign $DEBIAN_RELEASE $TARGET_DIR
  cp /usr/bin/qemu-arm-static $TARGET_DIR/usr/bin/
  cp /etc/resolv.conf $TARGET_DIR/etc
  chroot_deb $TARGET_DIR '/debootstrap/debootstrap --second-stage'
elif [ ${APTCACHER} ] ; then
 debootstrap $DEBIAN_RELEASE $TARGET_DIR http://localhost:3142/ftp.fr.debian.org/debian/
else
 debootstrap $DEBIAN_RELEASE $TARGET_DIR
fi

# mount proc, sys and dev
mount -t proc chproc $TARGET_DIR/proc
mount -t sysfs chsys $TARGET_DIR/sys
mount -t devtmpfs chdev $TARGET_DIR/dev || mount --bind /dev $TARGET_DIR/dev
mount -t devpts chpts $TARGET_DIR/dev/pts || mount --bind /dev/pts $TARGET_DIR/dev/pts

# Configure debian apt repository
cat <<EOT > $TARGET_DIR/etc/apt/sources.list
deb http://ftp.fr.debian.org/debian $DEBIAN_RELEASE main contrib non-free
deb http://security.debian.org/ $DEBIAN_RELEASE/updates main contrib non-free
EOT
cat <<EOT > $TARGET_DIR/etc/apt/apt.conf.d/71-no-recommends
APT::Install-Suggests "0";
EOT

if [ ${APTCACHER} ] ; then
 cat <<EOT > $TARGET_DIR/etc/apt/apt.conf.d/01proxy
Acquire::http::Proxy "http://localhost:3142";
EOT
fi

chroot_deb $TARGET_DIR 'apt-get update'


if [ -n $ENCRYPT ] ; then
  PACKAGES=$PACKAGES" dropbear busybox cryptsetup "
fi

# Add useful packages
chroot_deb $TARGET_DIR "$APT openssh-server ntp parted locales vim-nox bash-completion rng-tools $PACKAGES"
echo 'HRNGDEVICE=/dev/urandom' >> $TARGET_DIR/etc/default/rng-tools
echo '. /etc/bash_completion' >> $TARGET_DIR/root/.bashrc

# Use dhcp on boot
cat <<EOT > $TARGET_DIR/etc/network/interfaces
auto lo
iface lo inet loopback

allow-hotplug eth0
iface eth0 inet dhcp
  post-up ip a a fe80::42:babe/128 dev eth0

allow-hotplug usb0
iface usb0 inet dhcp
EOT

# Debootstrap optimisations from igorpecovnik
# change default I/O scheduler, noop for flash media, deadline for SSD, cfq for mechanical drive
cat <<EOT >> $TARGET_DIR/etc/sysfs.conf
block/mmcblk0/queue/scheduler = noop
#block/sda/queue/scheduler = cfq
EOT

# flash media tunning
if [ -f "$TARGET_DIR/etc/default/tmpfs" ]; then
  sed -e 's/#RAMTMP=no/RAMTMP=yes/g' -i $TARGET_DIR/etc/default/tmpfs
  sed -e 's/#RUN_SIZE=10%/RUN_SIZE=128M/g' -i $TARGET_DIR/etc/default/tmpfs
  sed -e 's/#LOCK_SIZE=/LOCK_SIZE=/g' -i $TARGET_DIR/etc/default/tmpfs
  sed -e 's/#SHM_SIZE=/SHM_SIZE=128M/g' -i $TARGET_DIR/etc/default/tmpfs
  sed -e 's/#TMP_SIZE=/TMP_SIZE=1G/g' -i $TARGET_DIR/etc/default/tmpfs
fi

# Generate locales
sed -i "s/^# fr_FR.UTF-8 UTF-8/fr_FR.UTF-8 UTF-8/" $TARGET_DIR/etc/locale.gen
sed -i "s/^# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" $TARGET_DIR/etc/locale.gen
chroot_deb $TARGET_DIR "locale-gen en_US.UTF-8"

# Update timezone
echo 'Europe/Paris' > $TARGET_DIR/etc/timezone
chroot_deb $TARGET_DIR "dpkg-reconfigure -f noninteractive tzdata"

if [ "$DEBIAN_RELEASE" = "jessie" ] ; then
  # Add fstab for root
  chroot_deb $TARGET_DIR "echo '/dev/mmcblk0p1 / ext4	defaults	0	1' >> /etc/fstab"
  # Configure tty
  install -m 755 -o root -g root ${REP}/config/ttyS0.conf $TARGET_DIR/etc/init/ttyS0.conf
  chroot_deb $TARGET_DIR 'cp /lib/systemd/system/serial-getty@.service /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service'
  chroot_deb $TARGET_DIR 'sed -e s/"--keep-baud 115200,38400,9600"/"-L 115200"/g -i /etc/systemd/system/getty.target.wants/serial-getty@ttyS0.service'
  # specifics packets add and remove
  #chroot_deb $TARGET_DIR "debconf-apt-progress -- apt-get -y install libnl-3-dev busybox-syslogd software-properties-common python-software-properties"
  #chroot_deb $TARGET_DIR "apt-get -y remove rsyslog"
  # don't clear screen tty1
  #chroot_deb $TARGET_DIR 'sed -e s,"TTYVTDisallocate=yes","TTYVTDisallocate=no",g -i /etc/systemd/system/getty.target.wants/getty@tty1.service'
  # enable root login for latest ssh on jessie
  chroot_deb $TARGET_DIR "sed -i 's/PermitRootLogin without-password/PermitRootLogin yes/' /etc/ssh/sshd_config"
else
  # Configure tty
  echo T0:2345:respawn:/sbin/getty -L ttyS0 115200 vt100 >> $TARGET_DIR/etc/inittab
fi

# Good right on some directories
chroot_deb $TARGET_DIR 'chmod 1777 /tmp/'
chroot_deb $TARGET_DIR 'chgrp mail /var/mail/'
chroot_deb $TARGET_DIR 'chmod g+w /var/mail/'
chroot_deb $TARGET_DIR 'chmod g+s /var/mail/'

# Set hostname
echo $DEB_HOSTNAME > $TARGET_DIR/etc/hostname
sed -i "1i127.0.1.1\t${DEB_HOSTNAME}" $TARGET_DIR/etc/hosts

# Add firstrun and secondrun init script
install -m 755 -o root -g root ${REP}/script/secondrun $TARGET_DIR/etc/init.d/
install -m 755 -o root -g root ${REP}/script/firstrun $TARGET_DIR/etc/init.d/
chroot_deb $TARGET_DIR "insserv firstrun >> /dev/null"

if [ $INSTALL_YUNOHOST ] ; then
  chroot_deb $TARGET_DIR "$APT git"
  chroot_deb $TARGET_DIR "git clone https://github.com/YunoHost/install_script /tmp/install_script"
  chroot_deb $TARGET_DIR "cd /tmp/install_script && ./autoinstall_yunohostv2"
fi

if [ $INSTALL_KERNEL ] ; then
  if [ $INSTALL_KERNEL = 'testing' ] ; then
    echo 'deb http://ftp.fr.debian.org/debian testing main' > $TARGET_DIR/etc/apt/sources.list.d/testing.list
    # Install linux-image, u-boot and flash-kernel from testing (Debian strech)
    cat <<EOT > ${TARGET_DIR}/etc/apt/preferences.d/kernel-testing
Package: linux-image*
Pin: release o=Debian,a=testing
Pin-Priority: 990

Package: u-boot*
Pin: release o=Debian,a=testing
Pin-Priority: 990

Package: flash-kernel*
Pin: release o=Debian,a=testing
Pin-Priority: 990

Package: *
Pin: release o=Debian,a=testing
Pin-Priority: 50
EOT

    umount_dir $TARGET_DIR
    chroot_deb $TARGET_DIR 'apt-get update'
    chroot_deb $TARGET_DIR 'apt-get upgrade -y --force-yes'
    mkdir $TARGET_DIR/etc/flash-kernel
    echo $FLASH_KERNEL > $TARGET_DIR/etc/flash-kernel/machine
    if [ -n $ENCRYPT ] ; then
      PACKAGES="stunnel dropbear busybox"
      echo 'LINUX_KERNEL_CMDLINE="console=tty0 hdmi.audio=EDID:0 disp.screen0_output_mode=EDID:1280x720p60 root=/dev/mapper/root cryptopts=target=root,source=/dev/mmcblk0p2,cipher=aes-xts-plain64,size=256,hash=sha1 rootwait sunxi_ve_mem_reserve=0 sunxi_g2d_mem_reserve=0 sunxi_no_mali_mem_reserve sunxi_fb_mem_reserve=0 panic=10 loglevel=6 consoleblank=0"' > $TARGET_DIR/etc/default/flash-kernel
      echo 'aes' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'aes_x86_64' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'aes_generic' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'dm-crypt' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'dm-mod' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'sha256' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'sha256_generic' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'lrw' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'xts' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'crypto_blkcipher' >> $TARGET_DIR/etc/initramfs-tools/modules
      echo 'gf128mul' >> $TARGET_DIR/etc/initramfs-tools/modules
    else
      echo 'LINUX_KERNEL_CMDLINE="console=tty0 hdmi.audio=EDID:0 disp.screen0_output_mode=EDID:1280x720p60 root=/dev/mmcblk0p1 rootwait sunxi_ve_mem_reserve=0 sunxi_g2d_mem_reserve=0 sunxi_no_mali_mem_reserve sunxi_fb_mem_reserve=0 panic=10 loglevel=6 consoleblank=0"' > $TARGET_DIR/etc/default/flash-kernel
    fi
    chroot_deb $TARGET_DIR "export DEBIAN_FRONTEND=noninteractive $APT linux-image-armmp flash-kernel u-boot-sunxi u-boot-tools $PACKAGES"
    if [ -n $ENCRYPT ] ; then
      echo 'root	/dev/mmcblk0p2	none	luks' >> $TARGET_DIR/etc/crypttab
      echo '/dev/mapper/root	/	ext4	defaults	0	1' > $TARGET_DIR/etc/fstab
      echo '/dev/mmcblk0p1	/boot	ext4	defaults	0	2' >> $TARGET_DIR/etc/fstab
      sed -i -e 's#DEVICE=#DEVICE=eth0#' $TARGET_DIR/etc/initramfs-tools/initramfs.conf
      cp /olinux/script/initramfs/cryptroot $TARGET_DIR/etc/initramfs-tools/hooks/cryptroot
#      cp /olinux/script/initramfs/openvpn $TARGET_DIR/etc/initramfs-tools/hooks/openvpn
      cp /olinux/script/initramfs/httpd $TARGET_DIR/etc/initramfs-tools/hooks/httpd
      cp /olinux/script/initramfs/httpd_start $TARGET_DIR/etc/initramfs-tools/scripts/local-top/httpd
      cp /olinux/script/initramfs/httpd_stop $TARGET_DIR/etc/initramfs-tools/scripts/local-bottom/httpd
      cp /olinux/script/initramfs/stunnel $TARGET_DIR/etc/initramfs-tools/hooks/stunnel
      cp /olinux/script/initramfs/stunnel.conf $TARGET_DIR/etc/initramfs-tools/
      cp /olinux/script/initramfs/stunnel_start $TARGET_DIR/etc/initramfs-tools/scripts/local-top/stunnel
      cp /olinux/script/initramfs/stunnel_stop $TARGET_DIR/etc/initramfs-tools/scripts/local-bottom/stunnel
      mkdir -p $TARGET_DIR/etc/initramfs-tools/root/www/cgi-bin
      cp /olinux/script/initramfs/index.html $TARGET_DIR/etc/initramfs-tools/root/www/
      cp /olinux/script/initramfs/unicorn.gif $TARGET_DIR/etc/initramfs-tools/root/www/
      cp /olinux/script/initramfs/post.sh $TARGET_DIR/etc/initramfs-tools/root/www/cgi-bin/
      chroot_deb $TARGET_DIR "update-initramfs -u -k all"
    fi
  else
    cp ${INSTALL_KERNEL}/*.deb $TARGET_DIR/tmp/
    chroot_deb $TARGET_DIR 'dpkg -i /tmp/*.deb'
    rm $TARGET_DIR/tmp/*
    cp ${INSTALL_KERNEL}/boot.scr $TARGET_DIR/boot/
    chroot_deb $TARGET_DIR "ln -s /boot/dtb/$DTB /boot/board.dtb"
    umount_dir $TARGET_DIR
  fi
fi

# Add 'olinux' for root password and force to change it at first login
chroot_deb $TARGET_DIR '(echo olinux;echo olinux;) | passwd root'
chroot_deb $TARGET_DIR 'chage -d 0 root'

# Remove useless files
chroot_deb $TARGET_DIR 'apt-get clean'
rm $TARGET_DIR/etc/resolv.conf

if [ ${CROSS} ] ; then
  rm $TARGET_DIR/usr/bin/qemu-arm-static
fi

if [ ${APTCACHER} ] ; then
  rm $TARGET_DIR/etc/apt/apt.conf.d/01proxy
fi


