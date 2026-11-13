# PostgreSQL roles and databases

The login roles and the databases live on db1, and db2 gets them through replication. The database `lab` holds test data, and `app` is set up as for an application, with an owner and a read-only login.

Checks: [07](../../../checks/07-postgres-remote.sh), [21](../../../checks/21-app-roles.sh) · Managed by: [Role postgresql](../ansible/postgresql.md)

## Setup

### Login roles

The roles for replication are on [Streaming replication](replication.md#setup).

| Part | Setup |
|---|---|
| `remote_test` | Login, `SELECT` and `INSERT` on `lab.failover_test` |
| `app` | Login role, owner of the schema `app`, where it creates its tables |
| `report` | Login role with `USAGE` on the schema `app`. Default privileges give it `SELECT` on every table `app` creates there. |
| Passwords | Set by hand, kept only in `.pgpass` files, mode 600 |

### Databases

| Part | Setup |
|---|---|
| `lab` | Test data: the tables `items` (10,000 rows) and `failover_test`, written by the failover client |
| `app` | Owner `postgres`. `CONNECT` only for `app` and `report`, none for `PUBLIC`. |
| `app` and `report` logins | From db2 only, and only to the database `app` |

## Tested

| Date | Test | Result |
|---|---|---|
| 2026-11-04 | `report` from db2 on the table `orders`, which `app` created after the default privileges | `SELECT` works with no `GRANT` on the table. `INSERT` fails with `permission denied for table orders`, a login to `lab` with `no pg_hba.conf entry`. |
