#!/bin/bash

# Copyright (C) 2022 Pirx Developers - https://pirx.dev/
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

run_dir=$(realpath ${0})
run_dir=$(dirname ${run_dir})

if ! [ -f "${run_dir}/lds.conf" ]; then
  echo "Error: lds.conf not found"
  exit 1
fi

. ${run_dir}/lds.conf

if [ -z "${image_url}" ]; then
  echo "Error: image_url not configured"
  exit 1
fi

if [ -z "${root_disk}" ] || [ "${root_disk}" = "${boot_disk}" ] || [ "${root_disk}" = "${swap_disk}" ]; then
  echo "Error: invalid configuration"
  exit 1
fi

lds_index=$(mktemp -q -u -p /tmp 2>/dev/null)
wget -q "${image_url}/lds.index" -O "${lds_index}"
if ! [ -s "${lds_index}" ]; then
  echo "Error: no index found at ${image_url}"
  exit 1
fi

while : ; do
  echo
  cat "${lds_index}" | while read index index_distro index_image index_description; do
    echo "${index}: ${index_description}"
  done
  echo
  echo "Select system to install:"
  read index
  if echo "${index}" | grep -q -E "^[0-9a-zA-Z]"; then
    distro=$(grep -E "^"${index}"\s+" "${lds_index}" | tr -s ' ' | cut -d ' ' -f2)
    image=$(grep -E "^"${index}"\s+" "${lds_index}" | tr -s ' ' | cut -d ' ' -f3)
    image_description=$(grep -E "^"${index}"\s+" "${lds_index}" | tr -s ' ' | cut -d ' ' -f4-)
  fi
  if ! [ -z "${distro}" ] && ! [ -z "${image}" ]; then
    rm -f "${lds_index}"
    break
  fi
done

if [ -z "${distro}" ]; then
  echo "Error: unknown distribution type"
  exit 1
fi

if [ "${distro}" != "tld" ] && [ "${distro}" != "pld" ] && [ "${distro}" != "debian" ] && [ "${distro}" != "devuan" ] && [ "${distro}" != "ubuntu" ]; then
  echo "Error: unsupported distribution type '${distro}'"
  exit 1
fi

if [ "${luks}" != "yes" ]; then
  luks="no"
fi
if [ "${luks_keyscript}" != "yes" ]; then
  luks_keyscript="no"
fi
if [ "${lvm}" != "yes" ]; then
  lvm="no"
fi

if [ "${luks}" == "yes" ] || [ "${lvm}" == "yes" ]; then
  boot_device_required="yes"
  if [ -z "${boot_partition_size}" ]; then
    boot_partition_size="256M"
  fi
else
  boot_device_required="no"
fi

if [ -d "/sys/firmware/efi" ]; then
  boot_type="uefi"
  if [ -z "${efi_partition_size}" ]; then
    efi_partition_size="128M"
  fi
else
  boot_type="bios"
fi

disk_list="${root_disk}"
if ! [ -z "${boot_disk}" ]; then
  disk_list="${disk_list} ${boot_disk}"
fi
if ! [ -z "${swap_disk}" ]; then
  disk_list="${disk_list} ${swap_disk}"
fi

echo
echo "Warning!"
echo "All contents of disk(s) ${disk_list} will erased!"
echo "Type YES to continue."
read disk_confirm
if [ "${disk_confirm}" != "YES" ]; then
  echo "Aborting..."
  exit 1
fi

sfdisk_config=$(mktemp -q -p /tmp 2>/dev/null)
if ! [ -z "${boot_disk}" ]; then
  echo "Partitioning boot disk ${boot_disk}"
  grub_device="${boot_disk}"
  partition_number=1
  cat > "${sfdisk_config}" <<EOF
label: dos
unit: sectors

EOF
  if [ "${boot_type}" = "uefi" ]; then
    cat >> "${sfdisk_config}" <<EOF
${boot_disk}${partition_number} : size=${efi_partition_size}, type=ef
EOF
    efi_device="${boot_disk}${partition_number}"
    partition_number=$((partition_number + 1))
  fi
  cat >> "${sfdisk_config}" <<EOF
${boot_disk}${partition_number} : type=83, bootable
EOF
  boot_device="${boot_disk}${partition_number}"
  sfdisk -q -w always --force ${boot_disk} < "${sfdisk_config}"
  result=$?
  rm -f "${sfdisk_config}"
  if [ "${result}" -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
fi

if ! [ -z "${swap_disk}" ]; then
  echo "Partitioning swap disk ${swap_disk}"
  cat > "${sfdisk_config}" <<EOF
label: dos
unit: sectors

${swap_disk}1 : type=82
EOF
  swap_device="${swap_disk}1"
  sfdisk -q -w always --force ${swap_disk} < "${sfdisk_config}"
  result=$?
  rm -f "${sfdisk_config}"
  if [ "${result}" -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
fi

root_device_partitioning_required="no"
if [ -z "${boot_disk}" ] && [ "${boot_type}" = "uefi" ]; then
  root_device_partitioning_required="yes"
fi
if [ -z "${boot_disk}" ] && [ "${boot_device_required}" = "yes" ]; then
  root_device_partitioning_required="yes"
fi
if [ -z "${swap_disk}" ] && ! [ -z "${swap_size}" ] && [ "${lvm}" = "no" ]; then
  root_device_partitioning_required="yes"
fi
if [ "${luks}" = "no" ] && [ "${lvm}" = "no" ]; then
  root_device_partitioning_required="yes"
fi

if [ "${root_device_partitioning_required}" = "yes" ]; then
  echo "Partitioning root disk ${root_disk}"
  partition_number=1
  cat > "${sfdisk_config}" <<EOF
label: dos
unit: sectors

EOF
  if [ -z "${boot_disk}" ]; then
    grub_device="${root_disk}"
    if [ "${boot_type}" = "uefi" ]; then
      cat >> "${sfdisk_config}" <<EOF
${root_disk}${partition_number} : size=${efi_partition_size}, type=ef
EOF
      efi_device="${root_disk}${partition_number}"
      partition_number=$((partition_number + 1))
    fi
    if [ "${boot_device_required}" = "yes" ]; then
      cat >> "${sfdisk_config}" <<EOF
${root_disk}${partition_number} : size=${boot_partition_size}, type=83, bootable
EOF
      boot_device="${root_disk}${partition_number}"
      partition_number=$((partition_number + 1))
    fi
  fi
  if [ -z "${swap_disk}" ] && ! [ -z "${swap_size}" ] && [ "${lvm}" = "no" ]; then
    cat >> "${sfdisk_config}" <<EOF
${root_disk}${partition_number} : size=${swap_size}, type=82
EOF
    swap_device="${root_disk}${partition_number}"
    partition_number=$((partition_number + 1))
  fi
  cat >> "${sfdisk_config}" <<EOF
${root_disk}${partition_number} : type=83
EOF
  root_device="${root_disk}${partition_number}"
  luks_device="${root_disk}${partition_number}"
  lvm_device="${root_disk}${partition_number}"
  sfdisk -q -w always --force ${root_disk} < "${sfdisk_config}"
  result=$?
  rm -f "${sfdisk_config}"
  if [ "${result}" -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
else
  luks_device="${root_disk}"
  lvm_device="${root_disk}"
fi

if [ "${luks}" == "yes" ]; then
  echo "Encrypting disk ${luks_device}"
  echo "${luks_key}" | cryptsetup -qv luksFormat ${luks_device}
  if [ $? -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
  echo "Opening encrypted disk ${luks_device}"
  echo "${luks_key}" | cryptsetup -qv luksOpen ${luks_device} ${luks_name}
  if [ $? -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
  luks_encrypted_device="/dev/mapper/${luks_name}"
  root_device="/dev/mapper/${luks_name}"
fi

if [ "${lvm}" == "yes" ]; then
  echo "Creating LVM PV & VG"
  if [ "${luks}" == "yes" ]; then
    pvcreate -f "${luks_encrypted_device}"
    if [ $? -ne 0 ]; then
      echo "Failed"
      exit 1
    fi
    vgcreate -f "${lvm_vg_name}" "${luks_encrypted_device}"
    if [ $? -ne 0 ]; then
      echo "Failed"
      exit 1
    fi
  else
    pvcreate -f "${lvm_device}"
    if [ $? -ne 0 ]; then
      echo "Failed"
      exit 1
    fi
    vgcreate -f "${lvm_vg_name}" "${lvm_device}"
    if [ $? -ne 0 ]; then
      echo "Failed"
      exit 1
    fi
  fi
  if [ -z "${swap_disk}" ] && echo "${swap_size}" | grep -q -E "^[0-9.]+[KMG]$" 2>/dev/null; then
    echo "Creating LVM LV for swap"
    lvcreate -n swap -L ${swap_size} "${lvm_vg_name}"
    if [ $? -ne 0 ]; then
      echo "Failed"
      exit 1
    fi
  fi
  echo "Creating LVM LV for root FS"
  if echo "${lvm_root_size}" | grep -q -E "^[0-9.]+[KMG]$" 2>/dev/null; then
    lvcreate -n root -L ${lvm_root_size} "${lvm_vg_name}"
  else
    lvcreate -n root -l 100%free "${lvm_vg_name}"
  fi
  if [ $? -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
  root_device="/dev/${lvm_vg_name}/root"
fi

if ! [ -z "${boot_device}" ]; then
  echo "Formatting ${boot_device} for /boot FS as ext4"
  mkfs.ext4 -q -F "${boot_device}"
  if [ $? -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
fi
if ! [ -z "${efi_device}" ]; then
  echo "Formatting ${efi_device} for /boot/efi as FAT"
  mkfs.vfat "${efi_device}"
  if [ $? -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
fi
if ! [ -z "${swap_device}" ]; then
  echo "Formatting ${swap_device} as swap space"
  mkswap -f "${swap_device}"
  if [ $? -ne 0 ]; then
    echo "Failed"
    exit 1
  fi
fi
echo "Formatting ${root_device} for root FS as ext4"
mkfs.ext4 -q -F "${root_device}"
if [ $? -ne 0 ]; then
  echo "Failed"
  exit 1
fi

dest_dir=$(mktemp -q -p /tmp -d 2>/dev/null)

mount "${root_device}" "${dest_dir}" 2>/dev/null

if [ "${boot_device_required}" == "yes" ]; then
  mkdir -p "${dest_dir}/boot" 2>/dev/null
  mount "${boot_device}" "${dest_dir}/boot" 2>/dev/null
fi

if ! [ -z "${efi_device}" ]; then
  mkdir -p "${dest_dir}/boot/efi" 2>/dev/null
  mount "${efi_device}" "${dest_dir}/boot/efi" 2>/dev/null
fi

echo "Installing ${image_description}, please wait."

cd "${dest_dir}"
wget -q --show-progress --progress=bar:force "${image_url}/${image}" -O- | tar Jxf -
cd "${run_dir}"

echo "Generating fstab"
rm -f "${dest_dir}/etc/fstab"
echo -e "proc\t/proc\tproc\tdefaults\t0\t0" >> "${dest_dir}/etc/fstab"
mount | grep " on "${dest_dir} | while read m_dev j1 m_path j2 m_fs m_opts; do
  m_path=$(echo "${m_path}" | sed -e 's!'"${dest_dir}"'!!g;' 2>/dev/null)
  if [ -z "${m_path}" ]; then
    m_path="/"
  fi
  if ! echo "${m_path}" | grep -q -E "^/(dev|proc|run|sys)$"; then
    echo -e "UUID=$(blkid -o value -s UUID "${m_dev}" 2>/dev/null)\t${m_path}\t${m_fs}\tdefaults\t0\t1" >> "${dest_dir}/etc/fstab"
  fi
done
for swap_dev in $(blkid -o value -s UUID -t TYPE="swap" 2>/dev/null); do
  echo -e "UUID=${swap_dev}\tnone\tswap\tdefaults\t0\t0" >> "${dest_dir}/etc/fstab"
done

if [ "${luks}" == "yes" ]; then
  if [ "${distro}" = "pld" ]; then
    luks_keyscript="no"
  fi
  echo "Generating crypttab"
  rm -f "${dest_dir}/etc/crypttab"

  luks_uuid=""
  luks_options=""
  if [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
    if [ "$luks_keyscript" = "yes" ]; then
      luks_options="luks,keyscript=/root/crypt/unlock.sh"
    else
      luks_options="luks"
    fi
  elif [ "${distro}" = "tld" ]; then
    if [ "$luks_keyscript" = "yes" ]; then
      luks_options="keyscript=/root/crypt/unlock.sh"
    fi
  fi
  for luks_dev in $(blkid -o device -t TYPE="crypto_LUKS" 2>/dev/null); do
    luks_dev=$(basename "${luks_dev}" 2>/dev/null)
    if ! [ -d "/sys/block/${luks_dev}" ]; then
      parent_dev=$(echo "${luks_dev}" | sed -r -e 's/[0-9]+$//' 2>/dev/null)
      dm_name=$(cat /sys/block/${parent_dev}/${luks_dev}/holders/dm-*/dm/name 2>/dev/null | head -n 1)
    else
      dm_name=$(cat /sys/block/${luks_dev}/holders/dm-*/dm/name 2>/dev/null | head -n 1)
    fi
    luks_uuid=$(blkid -o value -s UUID -t TYPE="crypto_LUKS" "/dev/${luks_dev}" 2>/dev/null)
    echo -e "${dm_name} UUID=${luks_uuid}\tnone\t${luks_options}"  >> "${dest_dir}/etc/crypttab"
  done

  if [ "$luks_keyscript" = "yes" ]; then
    echo "Generating keyscript for automatic LUKS unlocking"
    mkdir -p "${dest_dir}/root/crypt" 2>/dev/null
    cat > "${dest_dir}/root/crypt/unlock.sh" <<EOF
#!/bin/sh

echo -n "${luks_key}"
EOF
    chmod 700 "${dest_dir}/root/crypt/unlock.sh"
  fi
fi

for d in dev proc run sys; do
  if ! [ -d "${dest_dir}/${d}" ]; then
    mkdir -p "${dest_dir}/${d}" 1>/dev/null 2>&1
  fi
  mount /${d} "${dest_dir}/${d}" -o bind 1>/dev/null 2>&1
done

for kernel in $(chroot "${dest_dir}" /bin/ls -1 /lib/modules/ 2>/dev/null); do
  echo -n "Generating initramfs image for kernel ${kernel} ... "
  if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
    if [ -x "${dest_dir}/usr/bin/dracut" ]; then
      chroot "${dest_dir}" /sbin/dracut -vvv --force --hostonly /boot/initramfs-"${kernel}".img "${kernel}" 1>/dev/null 2>&1
      result=$?
    fi
  elif [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
    if [ -x "${dest_dir}/usr/sbin/mkinitramfs" ]; then
      chroot "${dest_dir}" /usr/sbin/mkinitramfs -v -o "/boot/initrd.img-${kernel}" "${kernel}" 1>/dev/null 2>&1
      result=$?
    fi
  fi
  if [ "${result}" -eq 0 ]; then
    echo "OK"
  else
   echo "FAILED"
  fi
done

if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
  grub_sysconfig="${dest_dir}/etc/sysconfig/grub"
elif [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
  grub_sysconfig="${dest_dir}/etc/default/grub"
fi

if [ "${network_legacy_ifnames}" = "yes" ]; then
  echo "Disabling predictable interface names"
  sed -i -r -e '/^GRUB_CMDLINE_LINUX_DEFAULT="/s/(net\.ifnames=[01]|biosdevname=[01])//g;' "${grub_sysconfig}" 2>/dev/null
  sed -i -r -e '/^GRUB_CMDLINE_LINUX_DEFAULT="\s+/s/^GRUB_CMDLINE_LINUX_DEFAULT="\s+/GRUB_CMDLINE_LINUX_DEFAULT="/g;' "${grub_sysconfig}" 2>/dev/null
  sed -i -r -e '/^GRUB_CMDLINE_LINUX_DEFAULT="/s/^GRUB_CMDLINE_LINUX_DEFAULT="(.*)".*/GRUB_CMDLINE_LINUX_DEFAULT="net.ifnames=0 biosdevname=0 \1"/g;' "${grub_sysconfig}" 2>/dev/null
  sed -i -r -e '/^GRUB_CMDLINE_LINUX_DEFAULT=".*\s+"/s/\s+"/"/g;' "${grub_sysconfig}" 2>/dev/null
fi

echo -n "Generating GRUB configuration ... "
if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
  chroot "${dest_dir}" /sbin/update-grub 1>/dev/null 2>&1
  result=$?
elif [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
  sed -i -e '/^GRUB_HIDDEN_TIMEOUT/s/^/#/g' "${grub_sysconfig}" 1>/dev/null 2>&1
  chroot "${dest_dir}" /usr/sbin/update-grub 1>/dev/null 2>&1
  result=$?
fi
if [ "${result}" -eq 0 ]; then
  echo "OK"
else
  echo "FAILED"
fi

echo -n "Installing GRUB on ${grub_device} ... "
if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
  chroot "${dest_dir}" /sbin/grub-install "${grub_device}" 1>/dev/null 2>&1
  result=$?
elif [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
  chroot "${dest_dir}" /usr/sbin/grub-install "${grub_device}" 1>/dev/null 2>&1
  result=$?
fi
if [ "${result}" -eq 0 ]; then
  echo "OK"
else
  echo "FAILED"
fi

echo -n "Setting password and shell for user root ... "
chroot "${dest_dir}" /usr/sbin/usermod -s /bin/bash -p "\$6\$3CgUstbuM9ka.6rd\$R6h3qSPUHtqBxhAs/e6L9ixN3uzghqWwf0H2oAA3aIthOF5Ks67qDpj9KlIyaurQ70V9C.eoaXNPMsVA576H20" root 1>/dev/null 2>&1
if [ "$?" -eq 0 ]; then
  echo "OK"
else
  echo "FAILED"
fi

if ! [ -z "${user_login}" ]; then
  echo -n "Creating user ${user_login} ... "
  chroot "${dest_dir}" /usr/sbin/useradd -u 1001 -U -m -s /bin/bash ${user_login} 1>/dev/null 2>&1
  if [ "$?" -eq 0 ]; then
    echo "OK"
    if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
      echo -n "Adding user ${user_login} to group 'wheel' ... "
      chroot "${dest_dir}" /usr/sbin/usermod -a -G wheel ${user_login} 1>/dev/null 2>&1
      if [ "$?" -eq 0 ]; then
        echo "OK"
      else
       echo "FAILED"
      fi
    fi
  else
   echo "FAILED"
  fi
fi

for key_type in "rsa" "ecdsa" "ed25519"; do
  ssh_key_file="/etc/ssh/ssh_host_${key_type}_key"
  if ! [ -f "${dest_dir}/${ssh_key_file}" ]; then
    echo -n "Generating ${key_type} SSH host key ... "
    chroot "${dest_dir}" /usr/bin/ssh-keygen -t "${key_type}" -f "${ssh_key_file}" -N '' 1>/dev/null 2>&1
    if [ "$?" -eq 0 ]; then
      chmod 600 "${dest_dir}/${ssh_key_file}"
      echo "OK"
    else
     echo "FAILED"
    fi
  fi
done

# umount /dev, /proc, /sys
for d in sys run proc dev; do
  mountpoint -q "${dest_dir}/${d}" 1>/dev/null 2>/dev/null
  if [ $? -eq 0 ]; then
    umount "${dest_dir}/${d}" 1>/dev/null 2>&1
  fi
done

if [ -z "${hostname}" ]; then
  hostname="${distro}"
fi
if ! [ -z "${hostname}" ]; then
  echo "Setting system hostname to ${hostname}"
  if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
    sed -i -e '/^HOSTNAME=/s/=.*$/='"${hostname}"'/' "${dest_dir}/etc/sysconfig/network"
  fi
  echo "${hostname}" > "${dest_dir}/etc/hostname"
fi

if [ "${network_config}" = "yes" ]; then
  if [ -z "${network_device}" ]; then
    network_device="eth0"
  fi
  echo "Configuring network device ${network_device}"
  host_ip=$(ip -br -f inet addr | grep -v -E "^lo\s+" | awk -F " " '{print $3}')
  host_gw=$(ip route | grep -E '^default via' | awk -F " " '{print $3}')

  if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
    cat > "${dest_dir}/etc/sysconfig/interfaces/ifcfg-${network_device}" <<EOF
DEVICE=${network_device}
ONBOOT=yes
BOOTPROTO=none
IPADDR=${host_ip}
GATEWAY=${host_gw}
EOF
    grep -E "^nameserver" /etc/resolv.conf > "${dest_dir}/etc/resolv.conf"
  elif [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
    host_cidr=$(echo "${host_ip}" | sed -e 's!^.*/!!')
    host_ip=${host_ip%/*}
    mask_value=$(( 0xffffffff ^ ((1 << (32 - ${host_cidr})) - 1) ))
    host_netmask="$(( (mask_value >> 24) & 0xff )).$(( (mask_value >> 16) & 0xff )).$(( (mask_value >> 8) & 0xff )).$(( mask_value & 0xff ))"
    cat > "${dest_dir}/etc/network/interfaces" <<EOF
auto lo
iface lo inet loopback

auto ${network_device}
iface ${network_device} inet static
  address ${host_ip}
  netmask ${host_netmask}
  gateway ${host_gw}
$(grep -E "^nameserver" /etc/resolv.conf | sed -e 's/^nameserver/  dns-nameserver/g;')
EOF
  fi
fi

if [ -z "${timezone}" ]; then
  timezone="Etc/UTC"
fi
echo "Setting timezone to ${timezone}"
timezone_esc=$(echo "${timezone}" | sed -e 's/\//\\\//g;' 2>/dev/null)
rm -f "${dest_dir}/etc/localtime"
if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
  sed -i -e '/^TIMEZONE=/s/=.*$/="'"${timezone_esc}"'"/g;' "${dest_dir}/etc/sysconfig/timezone"
fi
ln -s "/usr/share/zoneinfo/${timezone}" "${dest_dir}/etc/localtime"

if [ "${distro}" = "tld" ] || [ "${distro}" = "pld" ]; then
  home_path="/home/users"
elif [ "${distro}" = "debian" ] || [ "${distro}" = "devuan" ] || [ "${distro}" = "ubuntu" ]; then
  home_path="/home"
fi

mkdir "${dest_dir}${home_path}/${user_login}/"{tmp,.ssh} 2>/dev/null
chmod 700 "${dest_dir}${home_path}/${user_login}/"{tmp,.ssh} 2>/dev/null
chmod 600 "${dest_dir}${home_path}/${user_login}/".bash* 2>/dev/null
if ! [ -z "${user_login}" ] && ! [ -z "${user_ssh_key}" ]; then
  echo "Adding SSH key to account ${user_login}"
  cat "${run_dir}/${user_ssh_key}" > "${dest_dir}${home_path}/${user_login}/.ssh/authorized_keys"
  chmod 600 "${dest_dir}${home_path}/${user_login}/".ssh/authorized_keys 2>/dev/null
fi
user_uid_gid=$(grep -E "^"${user_login} ${dest_dir}/etc/passwd | cut -d ":" -f 3,4)
chown -R ${user_uid_gid} "${dest_dir}${home_path}/${user_login}/.ssh" 2>/dev/null

cp -f ${dest_dir}/etc/skel/.bash* ${dest_dir}/root/
chmod 600 ${dest_dir}/root/.bash*

if ! [ -z "${efi_device}" ]; then
  umount "${dest_dir}/boot/efi"
fi
if [ "${boot_device_required}" == "yes" ]; then
  umount "${dest_dir}/boot"
fi
umount "${dest_dir}"
if [ "${lvm}" == "yes" ]; then
  vgchange -a n
fi
if [ "${luks}" == "yes" ]; then
  cryptsetup luksClose ${luks_name}
fi
