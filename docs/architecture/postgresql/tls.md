# PostgreSQL TLS

Every login to PostgreSQL from another host uses TLS, with server certificates from the lab CA. Replication checks the certificate and the host name with `sslmode=verify-full`.

Checks: [22](../../../checks/22-tls.sh) · Managed by: [Role postgresql](../ansible/postgresql.md)

## Setup

| Part | Setup |
|---|---|
| CA | `CN=rhel-lab CA`, EC P-256, valid to 2036-11-01. Its key has a passphrase and stays on the desktop, outside the repo. |
| Server certificates | Signed by the CA, EC P-256, for server use only (`serverAuth`) |
| db1 certificate | `CN=db1` with `DNS:db1` and `IP:192.168.122.11`, valid to 2029-02-06 |
| db2 certificate | `CN=db2` with `DNS:db2` and `IP:192.168.122.12`, valid to 2029-02-07 |
| Files | `/pgdata/pgsql/tls/server.crt` (644) and `server.key` (600), owner `postgres`. The keys have no passphrase, so the server starts on its own. |
| Settings | `ssl = on`, with `ssl_cert_file` and `ssl_key_file` pointing to those files |
| Clients | `~/.postgresql/root.crt` with the CA certificate, for `postgres` and `makilele` on both hosts. libpq reads it by default. |

## Why

- `sslmode=verify-full` for replication, because `prefer` encrypts but does not check who answers. A host that poses as db1 could ask for the `replicator` password in clear text.

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-05 | Logins of `report` from db2 to `app` on db1 with `sslmode=disable`, with `verify-full`, and with `verify-full` to the name db2 at db1's address | `no pg_hba.conf entry … no encryption`. With `verify-full`, `ssl` is `t` with TLSv1.3. To the wrong name, `server certificate for "db1" (and 1 other name) does not match host name "db2"`. |
| 2026-11-05 | Logins of `replicator` and `rewind` from db1 to db2 with `verify-full`, then with the `host` of db2 and the `hostaddr` of db1, with `verify-full` and with `prefer` | `IDENTIFY_SYSTEM` answers on timeline 5, and `rewind` gets TLSv1.3. With the `hostaddr` of db1, `verify-full` stops before the password with `does not match host name "192.168.122.12"`. `prefer` logs in to db1 with no error, and after a refused login it tries again with no encryption. |
