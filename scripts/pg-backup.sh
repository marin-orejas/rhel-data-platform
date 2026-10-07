#!/usr/bin/env bash
# Back up all PostgreSQL databases, the roles and the config files.
# Usage: pg-backup.sh DEST_DIR [KEEP_DAYS]
# Installed on db1 as /usr/local/bin/pg-backup.sh and run as postgres:
#   sudo -u postgres /usr/local/bin/pg-backup.sh /mnt/db2/backup/pgsql
# It exits 1 when any step fails, and then it deletes no old backups.

# New files get mode 640: the group can read them, others cannot.
umask 027
# sudo -u, cron and systemd do not read the .bash_profile of postgres.
export PGPORT=${PGPORT:-5433}
# A pipe fails when pg_dump fails, not only when gzip does.
set -o pipefail
# find goes back to the start directory at the end, so it must be one postgres can enter.
cd /

failed=0
dest=${1%/}
keep=${2:-7}

if [ -z "$dest" ]; then
    echo "Usage: $0 DEST_DIR [KEEP_DAYS]" >&2
    exit 2
fi

if [ ! -d "$dest" ]; then
    echo "Error: $dest is not a directory" >&2
    exit 1
fi

if [ ! -w "$dest" ]; then
    echo "Error: cannot write to $dest" >&2
    exit 1
fi

stamp=$(date +%F_%H%M)
echo "Backup to $dest, stamp $stamp, keep $keep days"

# One query checks the connection and gives the data directory for the config archive.
pgdata=$(psql -Atc 'SHOW data_directory')
if [ -z "$pgdata" ]; then
    echo "Error: cannot connect to PostgreSQL on port $PGPORT" >&2
    exit 1
fi

# Templates are skipped. A database that does not accept connections fails the backup.
for db in $(psql -Atc 'SELECT datname FROM pg_database WHERE NOT datistemplate'); do
    file="$dest/$db-$stamp.sql.gz"
    echo "Dumping database $db to $file"
    if ! pg_dump "$db" | gzip > "$file"; then
        echo "Error: dump of database $db failed" >&2
        rm -f "$file"
        failed=$((failed + 1))
    fi
done

# Roles and their password hashes are not part of any database dump.
file="$dest/globals-$stamp.sql.gz"
echo "Dumping roles to $file"
if ! pg_dumpall --globals-only | gzip > "$file"; then
    echo "Error: dump of roles failed" >&2
    rm -f "$file"
    failed=$((failed + 1))
fi

file="$dest/config-$stamp.tar.bz2"
echo "Archiving config files to $file"
if ! tar -cjf "$file" -C "$pgdata" postgresql.conf postgresql.auto.conf pg_hba.conf pg_ident.conf; then
    echo "Error: archive of config files failed" >&2
    rm -f "$file"
    failed=$((failed + 1))
fi

# Keep the old backups when anything failed.
if [ "$failed" -gt 0 ]; then
    echo "Error: $failed step(s) failed" >&2
    exit 1
fi

echo "Deleting backups older than $keep days"
if ! find "$dest" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.tar.bz2' \) -mtime +"$keep" -print -delete; then
    echo "Error: deleting old backups failed" >&2
    exit 1
fi

echo "Backup finished"
