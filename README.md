## Linux Deployment Script

This script was written for quick deployment of new Linux systems on various
VPSs and VMs. All you need to do is to boot some rescue system on your VPS/VM,
clone/upload LDS there, edit `lds.conf` and run `lds` script.

Currently following systems are supported and avaiable:

* [Debian GNU/Linux](https://www.debian.org/) 10 Buster (with SysVinit or systemd)
* [Debian GNU/Linux](https://www.debian.org/) 11 Bullseye (with SysVinit or systemd)
* [Devuan Linux](https://devuan.org/) 3 Beowulf
* [Devuan Linux](https://devuan.org/) 4 Chimaera
* [PLD Linux](https://pld-linux.org/)
* [TLD Linux](https://tld-linux.org/)
* [Ubuntu Linux](https://ubuntu.com/) 18.04 Bionic
* [Ubuntu Linux](https://ubuntu.com/) 20.04 Focal
* [Ubuntu Linux](https://ubuntu.com/) 22.04 Jammy

Requirements:

* sfdisk for patitioning
* cryptsetup if you wish to encrypt your root device
* lvm2 if you wish to use LVM

Features:

* supports plain partitions or LUKS encrypted root device or root on LVM or root on LVM over LUKS encrypted device
* supports separate /boot and/or swap disks
* can configure network on installed system with same IPv4 address and DNS servers as used by the host system
* can create keyscript for automatic LUKS unlocking (if supported by chosen Linux distribution)
* can disable predictable network interface names and stick with legacy names like eht0
* can create user account on installed system and put SSH key on it
* will configure hostname and time zone on installed system

# BIG FAT WARNING

* LDS will erase all contents of devices used for installation! It will ask for confirmation but once you confirm all the data on selected devices will be permamently deleted. Be careful!
* LDS will set root password on installed system to `Linux`. Be sure to change it right after first boot of your new system.
