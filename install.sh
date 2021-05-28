#!/bin/bash
if [ "$(whoami)" != "root" ] ; then
   echo "try that again, with sudo, for example:"
   echo "  sudo $0"
   exit 0;
fi

apt-get update
apt-get install tree htop inotify-tools squashfs-tools aufs-tools inetutils-traceroute

if [ -e ./make-chroot-jail.sh ]; then
   [ -e /usr/local/bin/make-chroot-jail ] && chmod 777 /usr/local/bin/make-chroot-jail && rm /usr/local/bin/make-chroot-jail
   ln -s ./make-chroot-jail.sh /usr/local/bin/make-chroot-jail
   chmod 555 /usr/local/bin/make-chroot-jail
   echo "make-chroot-jail is now installed"
   echo "usage : sudo make-chroot-jail username [ /path/to/app ] [ramdiskMB]"
   echo "   note - the username specifed should be that does not yet exist. "
   echo "         (or has been previously used if you are updating)"
   echo "        - if you don't specify /path/to/app,  /app will be assume"
   echo "           this is the the source path that will be used to create the chroot file system"
   echo "        - using 0 for ramdiskMB disables the ramdisk, and enables diagnostic mode "
   
fi
