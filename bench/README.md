# PBM physical backup rate-limit benchmark

Local, disk-budgeted harness for the `--rate-limit-mb` / `backup.rateLimitMBs`
feature (physical backups). It runs a single-node PSMDB replica set, a MinIO
backend, a pbm-agent, and a steady read/update workload, then measures backups
with and without a bandwidth cap.

Measured results, exact machine specs, and interpretation: **[BENCHMARK.md](BENCHMARK.md)**.
Research context (upstream status, design questions, sources): **[RESEARCH.md](RESEARCH.md)**.

## Disk budget

The dataset is sized by its **on-disk** footprint (`SEED_TARGET_MB`, default
1500 MiB), not by document count, so it fits the free space on this host.
Peak usage with the default sweep (caps 0/20/10):

| Item | Approx. size |
|---|---|
| dbPath (dataset) | `SEED_TARGET_MB` |
| MinIO (one backup at a time; deleted after each run) | ~`SEED_TARGET_MB` |
| Docker images | ~2 GiB |
| Working headroom | ~1 GiB |

Run `df -h` before a larger sweep. The harness deletes each backup after
recording its metadata; it never keeps more than one copy in MinIO.

## Run

```sh
cd bench
./run.sh                          # 1.5 GiB dataset, caps 0/20/10
SEED_TARGET_MB=800 ./run.sh       # smaller disk footprint
CAPS="0 10 5" ./run.sh            # custom sweep
```

Choose caps below the host's observed uncapped throughput; a cap above it has
no effect. On this machine the storage ceiling was ~31 MiB/s, so the default
sweep uses 20 and 10 MiB/s. Each cap gets a discarded warmup backup first so
the measured run starts from a settled checkpoint/oplog state.

Results land in `bench/results/`: `summary.md`, `summary.csv`, raw
`runs.tsv`, `load.jsonl`, `metrics.tsv`, per-run `backup-<cap>.json`, and the
agent log.

## Layout

| Path | Purpose |
|---|---|
| `docker-compose.yaml` | mongod (host network, dbPath bind-mounted at the same absolute path), MinIO, bucket init, load generator |
| `pbm-s3.yaml` | PBM storage config for the local MinIO |
| `pbm-s3-ratelimit.yaml` | same, plus `backup.rateLimitMBs: 20` (config-only example) |
| `scripts/seed.js` | inserts a poorly-compressible dataset until `storageSize` reaches the target |
| `scripts/load.js` | 80/20 read/update workload, prints p50/p95/p99 per second |
| `scripts/collect.sh` | samples dbPath size, loopback RX bytes, agent CPU/RSS |
| `scripts/analyze.py` | slices load/metrics to each backup window and builds the table |
| `BENCHMARK.md` | measured results, machine specs, interpretation, tuning notes |
| `RESEARCH.md` | upstream status, design questions, sources |
| `results/` | last run's raw data and generated summary |

## Measurement notes and limitations

- **Rate-limit semantics:** the cap applies to the stream sent to storage
  (after compression). The sweep uses `--compression=none`, so the configured
  rate equals the bytes leaving the agent. The limiter is per uploading agent
  process; a single-node replica set makes that the whole deployment here.
- **`MB` means MiB:** the codebase reports sizes with `storage.MiB` under the
  label `MB`, and the cap uses the same convention (`rateLimitMBs` × MiB).
- **`lo` counters** include both S3 traffic and the workload's traffic to
  mongod. The workload is small relative to the backup stream; the table also
  reports effective upload rate from PBM metadata.
- **Page cache is warm** for all measured runs (a warmup backup runs first), so
  the numbers reflect stream pacing, not cold-disk reads. Dropping caches
  requires root and is not part of the harness.
- **No restore validation:** physical restore makes the agent stop and start
  `mongod`, which does not work when `mongod` is managed by Docker. Restore
  coverage stays with PBM's e2e suite.
- **dbPath growth** is the checkpoint-retention cost of a longer backup window
  (WiredTiger cannot delete checkpoints while the backup cursor is open). It is
  sampled every 0.5 s and reported per run.

## Cleanup

```sh
cd bench
docker compose down
rm -rf data results
```

MinIO keeps unfinished multipart uploads under `data/minio/.minio.sys/tmp`.
`run.sh` removes that directory after stopping the containers so repeated
sweeps do not accumulate disk usage.
