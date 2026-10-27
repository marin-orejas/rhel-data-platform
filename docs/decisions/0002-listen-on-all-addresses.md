# 0002. PostgreSQL listens on all addresses

Date: 2026-10-05
Status: Accepted

## Context

db2 connects to PostgreSQL on db1 over the network. `listen_addresses` could name the IP of db1 (`192.168.122.11`) or be `'*'`. The vendor unit of `postgresql` does not wait for the network, so at boot the IP of db1 may not exist yet when the server starts.

## Decision

`listen_addresses = '*'`, set with `ALTER SYSTEM`. Access is limited by the other three layers instead: the firewall opens `5433/tcp`, SELinux labels the port, and `pg_hba.conf` allows only `remote_test` from `192.168.122.12`.

## Consequences

- The server starts on every boot with remote access, whatever the order of the network and the database.
- It also listens on every other address of db1, so the firewall and `pg_hba.conf` are the real limits and must stay strict.
- A change of the IP of db1 needs no change in PostgreSQL.

Details: [PostgreSQL on db1](../architecture/postgresql.md)
