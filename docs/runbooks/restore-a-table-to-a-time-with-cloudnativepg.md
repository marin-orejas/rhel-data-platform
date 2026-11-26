# Restore a table to a set time with CloudNativePG

## When to use

When a change destroyed one table in the Cluster `pg`, such as a `DROP TABLE` or a bad `DELETE`, and the rest of the database must keep its later writes. A new Cluster `pg-restore` is built beside `pg` from the backups on db2, and the table is copied back, so `pg` stays up. How the backups are set up: [CloudNativePG backups](../architecture/kubernetes/cloudnativepg-backups.md).

## Before you start

- The SSH tunnel to the API server is open in a second terminal, for `kubectl` on the desktop ([Kubernetes cluster, Access from the desktop](../architecture/kubernetes/cluster.md#access-from-the-desktop)).
- The target time, with the time zone offset, for example `2026-11-24 20:54:51.827467+00`. The replay stops before the first commit after it.
- A backup that ended before the target: `First Point of Recoverability` in `kubectl cnpg status pg -n pg` is earlier. CloudNativePG picks the newest such backup itself.
- Room on a worker for one more instance: 1Gi in VG `data`, and 512Mi of memory requests, plus 256Mi for the plugin sidecar while the recovery runs.

## Steps

1. **desktop**: switch the primary to a new WAL segment, so that the segment with the bad commit goes to the archive. Run the second query until `last_archived_wal` shows the name the first one printed. Without that segment, the replay cannot see where to stop.

   ```bash
   kubectl cnpg psql pg -n pg -- -d app -c "SELECT pg_walfile_name(pg_switch_wal());"
   kubectl cnpg psql pg -n pg -- -d app -c "SELECT last_archived_wal, last_archived_time FROM pg_stat_archiver;"
   ```

2. **desktop**: set the target time in `kubernetes/apps/pg-restore/cluster.yaml`, under `bootstrap.recovery.recoveryTarget.targetTime`. Then make sure that the apply only creates the new Cluster: the diff shows one new object, `postgresql.cnpg.io.v1.Cluster.pg.pg-restore`, and no change to `pg`.

   ```bash
   kubectl diff -k kubernetes/apps/pg-restore/
   ```

3. **desktop**: build the copy and wait until it is ready. The Job `pg-restore-1-full-recovery` restores the backup and replays the WAL up to the target, then `pg-restore-1` starts as the primary of the copy.

   ```bash
   kubectl apply -k kubernetes/apps/pg-restore/
   kubectl wait cluster/pg-restore -n pg --for=condition=Ready --timeout=600s
   ```

4. **desktop**: check the table in the copy. `<table>` is the table to bring back.

   ```bash
   kubectl cnpg psql pg-restore -n pg -- -d app -c "SELECT count(*) FROM <table>;"
   ```

5. **desktop**: copy the table into `pg`. `<primary>` is the pod that `kubectl cnpg status pg -n pg` names as the primary, `pg-2` in the test. The table must not exist in `pg`, because the dump creates it.

   ```bash
   kubectl exec -n pg pg-restore-1 -c postgres -- pg_dump -d app -t <table> | kubectl exec -i -n pg <primary> -c postgres -- psql -d app
   ```

6. **desktop**: delete the copy. Its PVC `pg-restore-1` has the Cluster `pg-restore` as its owner, so it goes with it.

   ```bash
   kubectl delete -k kubernetes/apps/pg-restore/
   ```

## Check

- The table in `pg` has its row count from before the change, 5,000 rows with the same `sum(id)` in the test.
- `kubectl get pvc,pods -n pg` lists only `pg-1` and `pg-2`, and the pods kept their age and restarts, so `pg` had no outage.

Last tested: 2026-11-24 on k8s3, `restore_test` (5,000 rows) back in the primary `pg-2` after a drop, the copy ready in 67 s, no outage of `pg`
