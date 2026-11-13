# Rebuild the db hosts from fresh clones

## When to use

When the system disk of db1 or db2 is lost or broken but its data disk is intact, or to start both hosts again from `rhel-base`. Each host gets a new clone and keeps its data disk, and `ansible/playbooks/site.yml` builds the rest. What the playbook sets up: [Ansible playbooks](../architecture/ansible/playbooks.md).

## Before you start

- db1 is the primary and db2 its standby, as `ansible/inventory/host_vars/` says. After a failover to db2, the data disk of db1 still holds a primary, and the playbook would start it as a second one.
- The data disk of db1 holds the cluster. The roles set no passwords, so `replicator`, `rewind` and the app logins come from it.
- `rhel-base` is shut off, and the DHCP reservations of db1 and db2 exist ([VMs, Clones](../architecture/hosts/vms.md#clones)).
- The desktop has the Vault password file and the key `~/.ssh/id_ed25519_ansible` ([Ansible control node](../architecture/ansible/control-node.md)).

## Steps

1. **desktop**: copy `~/.pgpass` of db2 out of the VM. It holds the `remote_test` password for checks 07 and 13, and no role writes it.

   ```bash
   scp db2:.pgpass ~/.lab-secrets/db2.pgpass
   ```

2. **db1** and **db2**: unregister the old system, so it does not stay in the subscription after the disk is gone.

   ```bash
   sudo subscription-manager unregister
   ```

3. **nuc**: shut down db1 first, so db2 receives all of its WAL, then db2. Wait until `virsh list --all` shows both `shut off`.

   ```bash
   virsh shutdown db1
   virsh shutdown db2
   ```

4. **desktop**: save the definitions of both VMs outside the nuc. Keep them and the old system disks until the new hosts pass their checks.

   ```bash
   ssh nuc 'virsh dumpxml --inactive db1' > ~/db1-old.xml
   ssh nuc 'virsh dumpxml --inactive db2' > ~/db2-old.xml
   ```

5. **nuc**: remove both VMs and their UEFI variables. `undefine` keeps the disks.

   ```bash
   virsh undefine db1 --nvram
   virsh undefine db2 --nvram
   ```

6. **nuc**: move the old system disks aside. While `db1.qcow2` exists, `virt-clone --auto-clone` writes `db1-1.qcow2` without a warning.

   ```bash
   sudo mv /var/lib/libvirt/images/db1.qcow2 /var/lib/libvirt/images/db1-old.qcow2
   sudo mv /var/lib/libvirt/images/db2.qcow2 /var/lib/libvirt/images/db2-old.qcow2
   virsh pool-refresh default
   ```

7. **nuc**: clone db1 and db2 with [Clone a VM from the base image](clone-a-vm.md), steps 2 to 10. The data disks `db1-data.qcow2` and `db2-data.qcow2` go back as `vdb` in step 4.

8. **desktop**: from `ansible/`, load the Ansible key and create the user `ansible` on both clones. The bootstrap logs in as `makilele` with the lab key and asks for the sudo password.

   ```bash
   ssh-add ~/.ssh/id_ed25519_ansible
   ansible-playbook playbooks/bootstrap.yml -u makilele -K
   ```

9. **desktop**: from `ansible/`, build both hosts. When `/pgdata` on db2 is empty, the first run fails at the copy with `Connection refused`, because PostgreSQL on db1 starts later in the same play. Then run it again with `--limit db2`.

   ```bash
   time ansible-playbook playbooks/site.yml | tee ~/site-build.log
   ```

10. **desktop**: put `.pgpass` back on db2.

    ```bash
    scp ~/.lab-secrets/db2.pgpass db2:.pgpass
    ```

11. **desktop**: from `ansible/`, run the playbook again. Both hosts must show `changed=0`.

    ```bash
    ansible-playbook playbooks/site.yml
    ```

12. **desktop**: reboot both hosts. The boot activates the data VG from the LVM devices file and gives the journal its group and ACLs.

    ```bash
    ansible db -b -m ansible.builtin.reboot
    ```

13. **nuc**: when the checks below pass, delete the old system disks. Delete `~/db1-old.xml` and `~/db2-old.xml` on the desktop too.

    ```bash
    virsh vol-delete db1-old.qcow2 --pool default
    virsh vol-delete db2-old.qcow2 --pool default
    ```

## Check

- After the reboot, every script in [`checks/`](../../checks/) passes on the host its header names. [`checks/24-fresh-clones.sh`](../../checks/24-fresh-clones.sh) reads what makes each clone its own host, and its `site.yml --check` must give `changed=0`.
- From `ansible/`, `ansible-playbook playbooks/restore-test.yml` restores the newest backup on db2 and finds the same data as on the standby.

Last tested: 2026-11-13 on db1 and db2, db1 built in 3:46, the second run `changed=0` in 1:38, all checks pass after the reboot.
