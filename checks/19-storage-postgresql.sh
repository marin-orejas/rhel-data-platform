#!/usr/bin/env bash
# Lesson 19 checks: the data disks (role storage) and PostgreSQL (role postgresql) on db1 and db2.
# Reads the live state with read-only commands sent through Ansible as root: the mounts and
# their fstab lines, the packages, the service and its drop-in, the cluster and the postgres
# profile. Then a check run of playbooks/storage.yml and playbooks/postgresql.yml must change nothing.
# Run on the desktop from the repo root, with the key loaded (ssh-add ~/.ssh/id_ed25519_ansible):
#   bash checks/19-storage-postgresql.sh
# Run it after a reboot of both hosts.

failed=0

check() {
    local name=$1
    shift
    if "$@"; then
        echo "PASS  $name"
    else
        echo "FAIL  $name"
        failed=$((failed + 1))
    fi
}

hosts="db1 db2"
data_dir=/pgdata/pgsql/data
# Never ask for the passphrase: without the key in ssh-agent the login fails at once.
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

# ansible.cfg is read from the current directory
cd "$(dirname "$0")/../ansible" || exit 1

# Run one read-only command as root on a host and print only its output.
on() {
    ansible "$1" -b -m command -a "$2" "${opts[@]}" 2>/dev/null | tail -n +2
}

# A mount point comes from its LV, and its fstab line names the file system UUID of that LV.
check_mount() {
    local h=$1 dir=$2 lv=$3
    check "$h: $dir is mounted from $lv (xfs)" [ "$(on "$h" "findmnt -rno SOURCE,FSTYPE $dir")" = "$lv xfs" ]
    check "$h: fstab mounts $dir by the UUID of $lv" [ "$(on "$h" "findmnt --fstab -rno SOURCE $dir")" = "UUID=$(on "$h" "blkid -s UUID -o value $lv")" ]
}

for h in $hosts; do
    # Data disks
    check_mount "$h" /pgdata /dev/mapper/data-pgdata
    [ "$h" = db2 ] && check_mount "$h" /srv/backup /dev/mapper/data-backup

    # Packages
    check "$h: postgresql18-server and postgresql18-contrib are installed" [ "$(on "$h" "rpm -q postgresql18-server postgresql18-contrib" | grep -c '^postgresql18-')" -eq 2 ]

    # Service and its drop-in
    check "$h: the service has PGDATA=$data_dir" grep -Eq "(^| )PGDATA=$data_dir( |$)" <<< "$(on "$h" "systemctl show -p Environment --value postgresql")"
    check "$h: the service requires the mount /pgdata" grep -Eq "(^| )/pgdata( |$)" <<< "$(on "$h" "systemctl show -p RequiresMountsFor --value postgresql")"
    check "$h: postgresql is enabled" [ "$(on "$h" "systemctl is-enabled postgresql")" = enabled ]
    check "$h: postgresql is active" [ "$(on "$h" "systemctl is-active postgresql")" = active ]

    # The cluster on the data disk, and the profile for sudo -iu postgres
    check "$h: $data_dir holds a PostgreSQL 18 cluster" [ "$(on "$h" "cat $data_dir/PG_VERSION")" = 18 ]
    check "$h: the server runs from $data_dir" [ "$(on "$h" "runuser -u postgres -- psql -p 5433 -Atc 'show data_directory'")" = "$data_dir" ]
    check "$h: the postgres profile sets PGPORT=5433" [ "$(on "$h" "grep -x 'export PGPORT=5433' /var/lib/pgsql/.bash_profile")" = "export PGPORT=5433" ]
done

# The hosts match the playbooks: a check run would change nothing
for playbook in playbooks/storage.yml playbooks/postgresql.yml; do
    recap=$(ansible-playbook "$playbook" --check "${opts[@]}" 2>/dev/null)
    for h in $hosts; do
        check "$h matches $playbook (changed=0)" grep -Eq "^$h +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0 " <<< "$recap"
    done
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
