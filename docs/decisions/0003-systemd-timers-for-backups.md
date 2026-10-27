# 0003. systemd timers for backups, not cron

Date: 2026-10-06
Status: Accepted

## Context

The nightly backup on db1 has to run every day, also after a night when db1 was off, and a failure has to be visible. Both a systemd timer and the crontab of postgres were tried with the same script, every 2 minutes, to compare.

## Decision

Backups run from systemd timers: `pg-backup.timer` for the dumps, and `pgbackrest-full.timer` and `pgbackrest-diff.timer` for pgBackRest. Each starts a `Type=oneshot` service with `User=postgres`. cron is not used.

## Consequences

- `Persistent=true` starts a missed run right after the next boot. A crontab entry does not run when the host was off at that time.
- The output and the exit code go to the journal of the unit, and a failed backup leaves the unit `failed`. cronie writes the output to the journal (`journalctl -t CROND`) but not the exit code.
- Order and dependencies are part of the unit: `After=postgresql.service autofs.service`, `Wants=autofs.service`.
- Neither cron nor systemd reads the `.bash_profile` of postgres, so the script sets `PGPORT` itself.
- Two files per job instead of one crontab line.

Details: [Backups](../architecture/backups.md)
