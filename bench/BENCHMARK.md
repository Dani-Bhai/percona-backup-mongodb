# Physical backup bandwidth limiter — implementation and benchmark

**Date:** Nov 24, 2026 · **Base:** PBM `main` @ `ae300e0f` (Nov 23, 2026) · **Branch:** `physical-backup-rate-limit`

This is the PoC deliverable described in `RESEARCH.md`: a network bandwidth rate limiter for physical backups in Percona Backup for MongoDB, plus a load-test benchmark showing what it buys and what it costs.

---

## 1. What was implemented

| Area | Change |
|---|---|
| Config | `backup.rateLimitMBs` (MB/s, `0` = no limit) in `pbm/config/config.go`, with a nil-safe getter |
| CLI | `pbm backup --rate-limit-mb <n>`; value travels to agents in `ctrl.BackupCmd.RateLimitMBs` |
| Agent | `Backup.SetRateLimitMBs`; CLI value overrides config, config overrides "no limit" |
| Enforcement | Token bucket (`golang.org/x/time/rate`, already vendored) shared by all files of a backup; applied to the **post-compression stream** in `storage.UploadWithOpts`, so it caps the bytes actually sent to the storage backend |
| Backpressure | Uploads larger than the limiter burst are split into burst-sized `WaitN` calls (`rate.Limiter.WaitN` rejects `n > burst`); context cancellation propagates into the wait |

Semantics, as implemented:

- **Per uploading `pbm-agent` process.** Each replica set's elected backup node enforces its own cap; in a sharded cluster the deployment total is the sum over shards/config server. Deployment-wide coordination is deliberately out of scope (see `RESEARCH.md` §7).
- **Post-compression bytes.** With `--compression=none` the cap equals the wire rate; with compression the wire rate is lower than the cap by the compression ratio.
- **Burst:** 1 MiB. The limiter starts with one burst available, so short backups can finish slightly faster than `size / cap`.
- **Physical backups only** (including incremental physical, which shares `uploadPhysical`). Logical backups and PITR slicing are untouched.
- **Cancellation:** a canceled backup stops waiting immediately; the returned error is the context error or `storage.ErrCancelled`.

Code map: `pbm/storage/ratelimit.go` (new), `pbm/storage/storage.go` (`UploadWithOpts` option), `pbm/backup/physical.go` (limiter creation and pass-through), `pbm/backup/backup.go`, `pbm/config/config.go`, `pbm/ctrl/cmd.go`, `cmd/pbm/{main,backup,restore}.go`, `cmd/pbm-agent/backup.go`.

---

## 2. Test suite

All tests follow the existing style (table-driven, project `errors` package, testify where the package already uses it). The suite is deliberately small and disk-light: the largest test writes 256 KiB to a temp directory.

```sh
# limiter: pacing, burst splitting, cancellation, end-to-end fs upload (5 tests, ~0.5 s)
go test ./pbm/storage/ -run 'TestUploadWithRateLimit|TestWaitN|TestRateLimitedReader' -count=1 -v

# backup: config/CLI precedence and limiter construction (7 subtests)
go test ./pbm/backup/ -run 'TestGetRateLimitMBs|TestRateLimiter' -count=1 -v

# config: nil/zero/negative/value semantics
go test ./pbm/config/ -run 'TestBackupConfGetRateLimitMBs' -count=1 -v

# production build (vendored, gssapi)
make build
```

Results on this machine: all pass; `gofmt` clean; `go build -mod=vendor -tags gssapi ./cmd/... ./pbm/...` succeeds. The repo-wide `go vet` reports pre-existing unkeyed `bson.E` literals (excluded by the project's golangci configuration); none are introduced by this change. `golangci-lint` is not installed here.

Test coverage of the feature:

- `TestUploadWithRateLimit` — 256 KiB through the real `UploadWithOpts` → fs backend at 512 KiB/s; asserts the upload is paced (≥ half the theoretical delay) and the stored bytes match.
- `TestUploadWithRateLimitCancel` — cancels mid-upload; asserts prompt termination.
- `TestWaitNSplitsReadsLargerThanBurst` — a 4 KiB read against a 1 KiB burst does not fail.
- `TestRateLimitedReader{,Canceled}` — data integrity and context propagation.
- `TestGetRateLimitMBs` — nil config, nil backup section, config value, CLI override, zero fallback, negative = no limit.
- `TestRateLimiter` — nil when unset; correct rate and burst when set.

---

## 3. Benchmark

### 3.1 Environment

| Component | Value |
|---|---|
| Host | Dell Latitude 5490 laptop, bare metal (`systemd-detect-virt` = none) |
| CPU | Intel Core i5-8350U, 4 cores / 8 threads, 1.7 GHz base / 3.6 GHz max, 6 MiB L3 |
| RAM | 15 GiB usable; ~2.8 GiB available during the run; 19 GiB swap |
| Disk | Intel SSD PEKKF256G8 NVMe, 256 GB, btrfs on `/dev/mapper/root`, 45 GB free at run time |
| OS | Arch Linux, kernel 7.2.11-arch1-1, x86_64 |
| Toolchain | Go 1.27.1 (module toolchain go1.27.3), Docker 29.9.2, Compose 5.6.1, Python 3.11.15, jq |
| MongoDB | Percona Server for MongoDB 8.0.4, **single-node replica set**, 512 MiB WiredTiger cache |
| PBM | built from the feature branch (`make build`) |
| Storage | MinIO-compatible `pgsty/silo` (the image PBM's own e2e suite uses), loopback S3 |
| Load | `mongosh` in a separate container: 80% `findOne` / 20% `updateOne` by `_id`, client-side latency per second |
| Dataset | 200 MiB target on disk (189k docs, ~1 KiB poorly-compressible payload) → **639 MiB dbPath** including oplog, journal and indexes |

This is a laptop-class CPU and SSD; the uncapped ceiling was ~38 MiB/s. Treat the absolute numbers as a baseline for this host, not as universal values — the harness is designed to produce the same table on any machine.

The harness lives in `bench/` and sizes the dataset by **on-disk footprint** (`SEED_TARGET_MB`), not document count, so it fits the available disk. Peak usage of this run: ~640 MiB dbPath + ~640 MiB MinIO + ~1.3 GiB images. `bench/README.md` has the full budget and cleanup.

### 3.2 Method

1. Seed the dataset; run one global warmup backup (discarded).
2. Start the workload and let it warm up for 25 s; measure a clean baseline.
3. For each cap (`0`, `20`, `10` MiB/s):
   - run a discarded warmup backup with the same cap,
   - **restart `mongod`** to release checkpoints retained during the warmup, so every measured run starts from the same ~640 MiB dbPath,
   - run the measured backup with `--compression=none --wait`, record wall time, PBM metadata, and the agent-log upload phase,
   - delete the backup.
4. Throughout, sample dbPath size, loopback RX bytes, and agent CPU/RSS every 0.5 s.
5. Slice the per-second workload metrics to each backup window.

Collected per run: backup wall time, agent-log upload phase, backup size (PBM metadata), loopback RX bytes, DB p50/p95/p99 and ops/s, dbPath growth, and agent CPU/RSS. Not collected yet: mongod CPU, disk `iostat`, and per-thread agent CPU — add them for deeper tuning.

`--compression=none` makes the configured cap equal the bytes leaving the agent, removing compression ratio as a variable. Caps were chosen below the host's uncapped ceiling (~38 MiB/s); a cap above the ceiling has no effect (observed in a preliminary run with 50/200 MiB/s).

### 3.3 Results

Baseline (no backup): **p95 4.05 ms, p99 7.12 ms, ~645 ops/s**.

| Cap (MiB/s) | Backup (MiB) | Duration (s) | Upload phase (s) | Upload (MiB/s) | DB p95 med (ms) | DB p99 med (ms) | DB p99 max (ms) | Ops/s | dbPath growth (MiB) |
|---|---|---|---|---|---|---|---|---|---|
| none | 645.7 | 23.11 | 17 | 38.0 | 25.29 | 47.31 | 1451.14 | 157 | 200.2 |
| 20 | 645.6 | 40.08 | 35 | 18.4 | 8.80 | 12.66 | 23.32 | 315 | 200.2 |
| 10 | 636.4 | 75.08 | 69 | 9.2 | 13.76 | 18.53 | 486.32 | 281 | 200.3 |

Raw data: `bench/results/` (`runs.tsv`, `load.jsonl`, `metrics.tsv`, `agent.log`, `summary.csv`).

Agent resource use (sampled every 0.5 s):

| Cap (MiB/s) | Agent CPU (% of one core) | Agent max RSS (MiB) |
|---|---|---|
| none | 26.9 | 186.4 |
| 20 | 30.7 | 114.6 |
| 10 | 16.2 | 120.1 |

### 3.4 Interpretation

- **The limiter is accurate.** On the upload phase it delivered 18.4 MiB/s against a 20 MiB/s cap and 9.2 against 10 (92% each). End-to-end backup time includes ~6 s of fixed overhead (cursor setup, file list, metadata, status polling), which dominates at this small scale. The **config-only path** was validated separately: with `backup.rateLimitMBs: 20` in the config and no CLI flag, the upload phase ran at ~19.5 MiB/s (645 MiB in 33 s).
- **Uncapped backups are not free.** They ran at the host ceiling (38 MiB/s), cut workload throughput from ~645 to ~157 ops/s (4.1×), raised p95 latency 6.2×, and produced a 1.45 s stall.
- **20 MiB/s was the sweet spot in this run.** Backup took 1.7× longer (23 → 40 s), but p95 fell to 8.8 ms (2.2× baseline instead of 6.2×), throughput doubled to 315 ops/s, and the 1.4 s stall disappeared (p99 max 23 ms).
- **10 MiB/s did not improve latency further.** Backup took 3.2× longer (75 s), yet p95 was 13.8 ms and there was a 486 ms stall. The longer window crosses periodic checkpoint cycles; at this dataset size, the extra throttling buys exposure, not smoothness. This is exactly the kind of non-linear tradeoff the benchmark exists to expose.
- **Checkpoint retention is real but bounded here.** dbPath grew by ~200 MiB during every backup window regardless of duration — a step from the journal/checkpoint cycle, not a linear rate at this scale. On multi-hour, multi-TB backups the docs' warning about checkpoint accumulation matters more; the harness measures it so the report can state it rather than assume it.

### 3.5 Rate → backup-time table (the mentor's deliverable)

Using the measured 92% upload efficiency and the mentor's constraints (24 h window, up to ~10 TB):

`duration ≈ size / (cap × 0.92) + fixed overhead`

| Cap (MiB/s) | Largest backup in 24 h (TiB) | Approx. TB |
|---|---|---|
| 10 | 0.76 | 0.83 |
| 20 | 1.52 | 1.67 |
| 50 | 3.79 | 4.17 |
| 100 | 7.58 | 8.34 |
| **120** | **9.1** | **10.0** |

Consequences:

- A **10 TB daily backup needs ≥ ~120 MiB/s**; anything lower cannot finish in 24 h. Percona's own guidance (10 TB, 24 h) sets that floor.
- This host's uncapped ceiling is ~38 MiB/s, so it cannot meet the 10 TB/24 h target at all; the numbers above are about the limiter's efficiency, not this machine's capacity.
- The table is the parameterization guide the mentor asked for: pick the cap from the largest nightly backup, then verify against the 24 h budget.

### 3.6 Limitations (read before quoting numbers)

- **Single host, loopback storage.** Backup reads, MinIO writes, and the workload share one disk. The latency impact is therefore dominated by local disk contention; on a real network the mechanism is identical but magnitudes differ. A `tc`/`trickle` external-shaping baseline would separate the two.
- **One run per cap.** The cap-10 result in particular is a single sample crossing a checkpoint cycle; repeat runs are needed before treating the 20-vs-10 ranking as settled.
- **Small dataset.** 200 MiB of data (639 MiB dbPath) is far from the multi-TB target; fixed overhead (~6 s) is proportionally large.
- **The oplog is part of every physical backup** (~200 MiB here), as are the journal (~100 MiB) and indexes; "backup size" is not the dataset size.
- **`MB` means MiB** in PBM's size reporting and in this feature (`storage.MiB`); the tables use MiB/TiB consistently.
- **No restore validation.** Physical restore makes the agent stop/start `mongod`, which does not work with a Docker-managed `mongod`. Restore coverage stays with PBM's e2e suite.
- **Load generator shares the host CPU** with `mongod`; it runs in a separate container but not a separate machine.

### 3.7 Run on another machine

Prerequisites: Linux, Docker with Compose v2, Go 1.27+, `make`, a C compiler, Kerberos headers (`libkrb5-dev` on Debian/Ubuntu, `krb5-devel` on Fedora/RHEL), `jq`, `python3`, `curl`. Budget roughly 10 GB of free disk for the default 1.5 GiB dataset and one backup at a time.

```sh
git clone https://github.com/<you>/percona-backup-mongodb.git
cd percona-backup-mongodb
git checkout physical-backup-rate-limit
cd bench
./run.sh
```

Notes:

- The harness uses `pgsty/silo` for S3 because `minio/minio` may be unavailable or denied in some registries; it is the image PBM's own e2e suite uses.
- `${BENCH_DIR}/data/db` is bind-mounted at the same absolute path inside the container, so the host `pbm-agent` can read the physical files.
- Start with `SEED_TARGET_MB=200` to validate the pipeline, then scale up to your disk budget.
- Measure the uncapped ceiling first, then choose caps below it. A cap above the ceiling has no effect.
- All raw data lands in `bench/results/`; `scripts/analyze.py` regenerates `summary.md`/`summary.csv`.

### 3.8 Reproduce

```sh
cd bench
SEED_TARGET_MB=200 CAPS="0 20 10" LOAD_SECONDS=700 ./run.sh
# results: bench/results/summary.md and summary.csv
```

To sweep a larger dataset, raise `SEED_TARGET_MB` after checking `df -h`; the harness deletes each backup after recording it and cleans MinIO temp space on exit.

---

## 4. Follow-ups before this becomes a PR

1. **Confirm ownership with Percona** (forum topic + Jira ticket), then replace `PBM-XXXX` in the branch/commit with the real ID.
2. Decide the unit of the limit with maintainers: per agent (implemented), per node, or deployment-wide (distributed coordination).
3. Decide whether restores and PITR slicing should share the limiter (restores have the same network-spike problem in reverse).
4. Repeat the sweep 3–5× per cap, add an external `tc`-shaped baseline, and run on a multi-node replica set/sharded cluster.
5. Add a docs entry for `backup.rateLimitMBs` and `--rate-limit-mb` (docs live in the separate PBM docs repo), including the 24 h capacity table.
6. Consider exposing the effective limit in `pbm status`/backup metadata so operators can confirm what was applied.
