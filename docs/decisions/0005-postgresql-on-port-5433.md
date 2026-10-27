# 0005. PostgreSQL on port 5433

Date: 2026-10-05
Status: Accepted

## Context

PostgreSQL listens on 5432 by default, and the SELinux policy and firewalld already know that port. This is a learning lab, and a service on a non-default port is a common admin task and an RHCSA topic: every layer that knows the port has to be changed by hand.

## Decision

PostgreSQL on db1 listens on 5433. The port is set with `ALTER SYSTEM`, labeled `postgresql_port_t` with `semanage port`, and opened as `5433/tcp` in firewalld.

## Consequences

- Every client has to name the port. The postgres user's `.bash_profile` sets `PGPORT=5433`, and `scripts/pg-backup.sh` sets it itself, because `sudo -u`, cron and systemd do not read that file.
- The local socket is `.s.PGSQL.5433`, so a client without the port looks for `.s.PGSQL.5432` and fails.
- The firewalld service `postgresql` cannot be used, because it opens 5432.
- The other port is not a security measure. Access is limited by the firewall and `pg_hba.conf`.

Details: [PostgreSQL on db1](../architecture/postgresql.md)
