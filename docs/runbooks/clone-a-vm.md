# Clone a VM from the base image

## When to use

To make a new VM such as db1 or db2 from `rhel-base`. A clone starts with the identity of `rhel-base`, so its hostname, machine ID, SSH host keys and registration must change before it is used. Why each one must change: [VMs, Clones](../architecture/vms.md#clones).

## Before you start

- `rhel-base` is shut off.
- The new VM has a MAC address and an IP address from the table in [VMs](../architecture/vms.md#clones). The example below is db1.
- A shell on the nuc as a user in the `libvirt` group.

## Steps

1. **nuc**: add a DHCP reservation for the new MAC address. The network name comes first, and the host is an XML fragment in quotes.

   ```bash
   virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:11' name='db1' ip='192.168.122.11'/>" --live --config
   ```

2. **nuc**: clone the base image. `virt-clone` copies the disk and the UEFI variables and gives the clone a new UUID.

   ```bash
   virt-clone --original rhel-base --name db1 --mac 52:54:00:00:00:11 --auto-clone
   ```

3. **nuc**: set the RAM to 3 GB in the saved config. A change with `--config` takes effect only after a full shutdown and `virsh start`, not after a reboot inside the guest.

   ```bash
   virsh setmaxmem db1 3G --config
   virsh setmem db1 3G --config
   ```

4. **nuc**: start the clone and open its serial console. Only one console session per VM can be open, and none may be open in Cockpit.

   ```bash
   virsh start db1
   virsh console db1
   ```

5. **db1**, in the console: set the hostname, create a new machine ID, delete all SSH host key pairs and reboot. `sshd-keygen` creates new keys at the next boot.

   ```bash
   sudo hostnamectl set-hostname db1
   sudo rm /etc/machine-id
   sudo systemd-machine-id-setup
   sudo rm /etc/ssh/ssh_host_*
   sudo reboot
   ```

6. **db1**, in the console: print the fingerprint of the new host key. The first `ssh db1` from the desktop must show the same fingerprint.

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

7. **db1**: register the system and update it.

   ```bash
   sudo subscription-manager register
   sudo dnf -y upgrade
   ```

8. **nuc**: turn on autostart for the clone. `rhel-base` stays without it.

   ```bash
   virsh autostart db1
   ```

## Check

- The machine ID, the SSH fingerprint and the subscription identity are different on nuc, rhel-base, db1 and db2: `cat /etc/machine-id`, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, `sudo subscription-manager identity`.
- From another VM, the name resolves to the reserved IP: `getent hosts db1` returns `192.168.122.11`.
- After a reboot of the nuc, the clone runs with the same IP, hostname and RAM, and SSH asks for no new host key.

Last tested: 2026-09-29 on db1 and db2, both clones running after a reboot of the nuc
