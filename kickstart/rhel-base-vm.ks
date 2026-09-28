# RHEL 10.2 kickstart for the base VM image (rhel-base)
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
network --bootproto=dhcp --device=link --activate --hostname=rhel-base

# Users
rootpw --lock
user --name=makilele --groups=wheel --iscrypted --password=@USER_HASH@
sshkey --username=makilele "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ5aKHnd0Dejhp4dB/BkdaRgBKpGyyJDM10wBWxbxDIK lab@desktop"

# Security
selinux --enforcing
firewall --enabled --service=ssh

# Disk
ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel
# EFI and /boot from reqpart, VG rhel (root 15 GiB, swap 2 GiB, the rest left free)
reqpart --add-boot
part pv.01 --size=1 --grow
volgroup rhel pv.01
logvol / --vgname=rhel --name=root --size=15360 --fstype=xfs
logvol swap --vgname=rhel --name=swap --size=2048
bootloader --append="console=ttyS0,115200"

# Software
%packages
@^minimal-environment
openssh-server
chrony
qemu-guest-agent
tuned
%end
