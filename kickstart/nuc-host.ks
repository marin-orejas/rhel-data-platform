# RHEL 10.2 kickstart for the NUC lab host
# USER_HASH is a placeholder, filled in with sed before install

# Installer
text
eula --agreed
reboot

# Locale
lang en_US.UTF-8
keyboard --vckeymap=hr --xlayouts='hr'
timezone Europe/Zagreb --utc

# Network
network --bootproto=static --device=enp85s0 --ip=192.168.1.50 --netmask=255.255.255.0 --gateway=192.168.1.1 --nameserver=192.168.1.1 --hostname=nuc

# Users
rootpw --lock
user --name=makilele --groups=wheel --iscrypted --password=@USER_HASH@
sshkey --username=makilele "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5aKHnd0Dejhp4dB/BkdaRgBKpGyyJDM10wBWxbxDIK lab@desktop"

# Security
selinux --enforcing
firewall --enabled --service=ssh

# Disk
ignoredisk --only-use=sda
zerombr
clearpart --all --initlabel
# EFI 600 MiB, /boot 1 GiB, VG rhel (root 30 GiB, swap 4 GiB), VG vms (images 60 GiB)
part /boot/efi --fstype=efi --size=600
part /boot --fstype=xfs --size=1024
part pv.01 --size=35840
part pv.02 --size=1 --grow
volgroup rhel pv.01
logvol / --vgname=rhel --name=root --size=30720 --fstype=xfs
logvol swap --vgname=rhel --name=swap --size=4096
volgroup vms pv.02
logvol /var/lib/libvirt/images --vgname=vms --name=images --size=61440 --fstype=xfs

# Software
%packages
@^minimal-environment
openssh-server
chrony
%end
