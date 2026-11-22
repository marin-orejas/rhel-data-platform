#!/usr/bin/env bash

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
key=~/.ssh/id_ed25519_ansible
playbook=playbooks/base.yml
opts=(--timeout 10 "--ssh-extra-args=-o BatchMode=yes")

export ANSIBLE_NOCOLOR=1

cd "$(dirname "$0")/../ansible" || exit 1

check "ansible-core is installed" rpm -q --quiet ansible-core
check "ansible reads $PWD/ansible.cfg" grep -qx "  config file = $PWD/ansible.cfg" <(ansible --version)
check "the group db holds db1 and db2" [ "$(ansible db --list-hosts | tail -n +2 | xargs)" = "$hosts" ]
check "the key $key is loaded in ssh-agent" grep -qF "$(ssh-keygen -lf "$key.pub" | awk '{print $2}')" <(ssh-add -l)

for h in $hosts; do
    check "$h: ansible logs in with the key" grep -q "\"ping\": \"pong\"" <(ansible "$h" -m ping "${opts[@]}" 2>/dev/null)
    check "$h: ansible has UID and GID 1500" grep -q "^uid=1500(ansible) gid=1500(ansible) " <(ansible "$h" -m command -a id "${opts[@]}" 2>/dev/null)
    check "$h: sudo gives root without a password" grep -qx root <(ansible "$h" -b -m command -a whoami "${opts[@]}" 2>/dev/null)
done

recap=$(ansible-playbook "$playbook" --check "${opts[@]}" 2>/dev/null)
for h in $hosts; do
    check "$h matches $playbook (changed=0)" grep -Eq "^$h +: ok=[0-9]+ +changed=0 +unreachable=0 +failed=0 " <<< "$recap"
done

echo
if [ "$failed" -eq 0 ]; then
    echo "All checks passed."
else
    echo "$failed check(s) failed."
fi
exit "$failed"
