# Clone a VM from the base image

## When to use

To make a new VM such as db1 or db2 from `rhel-base`, or to give a VM a new system disk and keep its data disk ([Rebuild the db hosts from fresh clones](rebuild-the-db-hosts-from-fresh-clones.md)). A clone starts with the identity of `rhel-base`, so its hostname, machine ID, SSH host keys and registration must change before it is used. Why each one must change: [VMs, Why](../architecture/hosts/vms.md#why).

## Before you start

- `rhel-base` is shut off.
- The new VM has a MAC address and an IP address from the table in [VMs](../architecture/hosts/vms.md#clones). The example below is db1.
- A shell on the nuc as a user in the `libvirt` group.

## Steps

1. **nuc**: add a DHCP reservation for a new MAC address. A clone with the MAC of an earlier VM keeps its reservation. The network name comes first, and the host is an XML fragment in quotes.

   ```bash
   virsh net-update default add ip-dhcp-host "<host mac='52:54:00:00:00:11' name='db1' ip='192.168.122.11'/>" --live --config
   ```

2. **nuc**: clone the base image. `virt-clone` copies the disk and the UEFI variables and gives the clone a new UUID.

   ```bash
   virt-clone --original rhel-base --name db1 --mac 52:54:00:00:00:11 --auto-clone
   ```

3. **nuc**: set the RAM to 3 GB in the saved config, the maximum first. A change with `--config` takes effect only after a full shutdown and `virsh start`, not after a reboot inside the guest.

   ```bash
   virsh setmaxmem db1 3G --config
   virsh setmem db1 3G --config
   ```

4. **nuc**: when the VM keeps a data disk, attach it to the saved config as `vdb`. Without `--subdriver qcow2`, libvirt reads the qcow2 file as a raw disk.

   ```bash
   virsh attach-disk db1 /var/lib/libvirt/images/db1-data.qcow2 vdb --driver qemu --subdriver qcow2 --targetbus virtio --config
   ```

5. **nuc**: start the clone and open its serial console. Only one console session per VM can be open, and none may be open in Cockpit. If the first start fails on `swtpm_setup`, start it again.

   ```bash
   virsh start db1
   virsh console db1
   ```

6. **db1**, in the console: set the hostname, create a new machine ID, delete all SSH host key pairs and reboot. `sshd-keygen` creates new keys at the next boot.

   ```bash
   sudo hostnamectl set-hostname db1
   sudo rm /etc/machine-id
   sudo systemd-machine-id-setup
   sudo rm /etc/ssh/ssh_host_*
   sudo reboot
   ```

7. **db1**, in the console: print the fingerprint of the new host key. The first `ssh db1` from the desktop must show the same fingerprint.

   ```bash
   ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
   ```

8. **desktop**: when the IP had a VM before, remove its old host key. `known_hosts` holds the IP from `~/.ssh/config`, not the name, so `ssh-keygen -R db1` finds nothing.

   ```bash
   ssh-keygen -R 192.168.122.11
   ```

9. **db1**: register the system, update it and reboot into the new kernel.

   ```bash
   sudo subscription-manager register
   sudo dnf -y upgrade
   sudo reboot
   ```

10. **nuc**: turn on autostart for the clone. `rhel-base` stays without it.

    ```bash
    virsh autostart db1
    ```

## Check

- The machine ID, the SSH fingerprint and the subscription identity are different on nuc, rhel-base, db1 and db2: `cat /etc/machine-id`, `ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub`, `sudo subscription-manager identity`.
- From another VM, the name resolves to the reserved IP: `getent hosts db1` returns `192.168.122.11`.
- With a data disk, `lsblk -f /dev/vdb` shows `vdb1` as `LVM2_member`. Its volumes show only after `ansible/playbooks/storage.yml` adds the disk to the LVM devices file.
- After a reboot of the nuc, the clone runs with the same IP, hostname and RAM, and SSH asks for no new host key.

Last tested: 2026-11-12 on db1 and db2, new clones with their old data disks, both running after a reboot of the nuc on 2026-11-13
