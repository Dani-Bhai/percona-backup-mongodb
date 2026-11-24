# PBM Backup Speed Throttling — Research Report

**Topic:** Network bandwidth rate limiter for physical backups in Percona Backup for MongoDB (PBM), plus a load-test benchmark measuring its impact on backup duration and database performance.

**Date:** Nov 24, 2026 · Sources verified against `percona/percona-backup-mongodb` `main` @ `ae300e0f` (Nov 23, 2026, shallow clone at `/tmp/opencode/pbm`).

> **Implementation status (this workspace):** the PoC is implemented on branch `physical-backup-rate-limit` with unit/integration tests, and benchmarked end-to-end. See **`BENCHMARK.md`** for the code map, test results, and measured tradeoff table. Upstream `main` still has no throttling.

---

## 1. The project idea — exact source

From the Percona forum post **"Google Summer of Code 2026: Project Ideas"** (forums.percona.com/t/40141, Feb 2, 2026, by Radosław Szulgo):

> **Percona Backup for MongoDB backup speed throttling**
>
> On large-scale deployments, backups may significantly impact network performance - specifically, network bandwidth may be heavily utilized, if the backup storage is fast, causing performance degradation of the database itself. Database reliability engineers would like to reduce the network load by slowing down physical backups with Percona Backup for MongoDB (PBM) configuration. The scope of the project is to implement a network bandwidth rate limiter and perform load testing showing the impact or rate limiting on backup time.
>
> **Deliverables:** The expected outcome of this project is insurance that backup will not degrade network bandwidth impacting the database. As a result a participant needs to provide proposed code changes in a form of fork of PBM and a create a report with load test results.
>
> **Required/preferred skills:** Go · **Duration:** 175 hours · **Difficulty:** Easy
> **Mentors:** @radoslaw.szulgo, @Boris_Ilijic
> **Repo:** github.com/percona/percona-backup-mongodb

The identical idea was listed for GSoC **2025** as well (forums.percona.com/t/36461). It was never selected/implemented in 2025 — no rate-limit code exists in the repo as of Nov 2026.

### Status caveat — confirmed

Percona itself confirmed (same thread, Feb 18, 2026, Radosław Szulgo):

> "Sadly, Google was unable to accept Percona this year as a mentoring organization for Google Summer of Code 2026. This year they received more applications than available slots.
>
> Still, we welcome all of you in our community and invite you to collaborate on Percona projects. If you're interested, let us know, and we will support you in collaboration, provide the required help to onboard the project, and give some mentoring."

So: **the idea has no owner and no GSoC slot in 2026, but Percona explicitly offers informal mentoring for exactly this kind of contribution.** First step is to open a topic in the PBM sub-forum (as the mentor told a 2025 applicant: "start engaging with the community — for example, by opening a topic in the PBM sub-forum and share your research results").

### Mentor's design answers (from the 2025 thread, Feb 11, 2025 — still the best on-record guidance)

Asked whether a rate-limiting approach was planned and what trade-off is acceptable, Radosław Szulgo answered:

> "That will be a completely new feature to design. **The maximum backup time is 24 hours**, as users usually schedule daily snapshots. **The largest backup size I have seen so far is about 10 TB.** I expect some benchmark testing and **a user guide in a table that shows how to parameterize the rate-limiter to receive a given backup time estimation**."

Design targets this implies:
- Usable cap range: from whatever saturates a fast pipe down to ~**121 MB/s** (10 TB / 24 h ≈ 0.97 Gbps). Below that, daily backups can't finish — the floor for a sensible config table.
- The deliverable isn't just code: it's the code **plus a table** mapping rate-limit setting → estimated backup time, backed by measurements.

### Real-world pain — operator feature request (Jan 2021, forums.percona.com/t/8664)

Nathan Neulinger, on physical backup to fast S3 storage:

> "...this results in an extreme network spike when the full backup kicks off - multiple gigabit spike for a short period, which is being felt in other apps/servers."

He sketched three implementation levels — a naive `putDelay` sleep after every put; a per-chunk rate limit ("if you set a limit of 10MB/sec, and the upload of a particular 10Mbyte chunk took 500ms, do a 500ms delay"); and an **upload concurrency override**, complaining that PBM "hard code[s] at NumCPU/2". His interim workaround was the userspace `trickle` proxy. Note: the NumCPU/2 hardcode still exists today in `pbm/storage/s3/s3.go:366` (`cc := runtime.NumCPU() / 2`).

---

## 2. How PBM physical backups work (what the limiter must wrap)

Architecture (docs + `pbm-architecture.png` + AGENTS.md in repo):

- **`pbm-agent`** runs on every non-arbiter `mongod` node. There is **no central coordinator** — agents coordinate entirely through "PBM Control collections" in MongoDB itself (locks, command queue, backup state).
- **`pbm` CLI** writes commands into control collections; agents pick them up.
- Physical backup = copying WiredTiger data/journal/index files from `dbPath` to remote storage, with **no database-level export** — that's why it's fast and why the remaining impact is network/disk I/O, the thing being throttled.

Physical backup flow (per replica set; for a sharded cluster, each shard + config server does this concurrently):

1. The agent elected as backup leader opens a **`$backupCursor`** aggregation on its node — PSMDB feature (WiredTiger; requires Percona Server for MongoDB ≥ 7.0, or MongoDB Enterprise via 2026-era PR #1285). Returns metadata + the list of files to copy.
2. Cluster-wide recovery timestamp agreed (each replica set's last-write TS; leader picks the most recent).
3. `$backupCursorExtend` returns the journal files up to the common timestamp.
4. Each replica set's chosen node copies files to storage; metadata saved; cursors closed.

**Critical operational constraint for throttling:** while a backup cursor is open, WiredTiger **can create checkpoints but cannot delete any**. Slower upload ⇒ cursor open longer ⇒ **`dbPath` disk usage grows for the whole backup window** (docs warn about "significant disk space growth"). This is the *real cost column* of the benchmark: a cap that "protects the network" but doubles the backup window doubles the checkpoint-retention window too. The honest report must measure dbPath growth, not just duration/latency.

Other mechanics worth knowing:
- Files can arrive as **16 MB blocks** (default) which PBM coalesces into contiguous ranges (`planUploads`, `pbm/backup/physical.go:698`).
- Incremental physical backups skip unchanged files (Len == 0) but still record them in metadata.
- PITR oplog slicing runs **in parallel** with the snapshot since 2.4.0 — a separate stream the limiter may or may not cover (design question).
- `numParallelFiles` (filesystem storage only) controls upload worker count, default 1.

---

## 3. The exact code path a rate limiter would wrap (verified on current `main`)

```
pbm-agent  cmd/pbm-agent/backup.go:112  defs.PhysicalBackup → backup.NewPhysical(...)
          └─ pbm/backup/physical.go  doPhysical()        -- backup cursors, timestamps
              └─ uploadPhysical()                        -- physical.go:527
                  └─ uploadFiles()                       -- physical.go:740  ← errgroup worker pool
                      │    numWorkers = getNumParallelFiles()   (backup.go:106)
                      └─ writeFile()                     -- physical.go:821
                          └─ storage.UploadWithOpts()    -- pbm/storage/storage.go:295
                                │
                                │   io.Pipe wiring:
                                │   goroutine A: src.WriteTo(compressWriter) → pipeWriter
                                │   goroutine B: stg.Save(fname, pipeReader, opts...)
                                │
                                ├─ fs.Save   → writeSync → io.CopyBuffer    (fs/fs.go:223)
                                └─ s3.Save   → aws-sdk-go-v2 manager.Uploader
                                               Concurrency = NumCPU/2       (s3/s3.go:366)
                                               PartSize    = 10 MB default   (s3/s3.go:416,
                                                                    via ComputePartSize)
```

Key facts about the stream:

- `storage.Source` is just `io.WriterTo` (`storage.go:270`). The disk read side is `File.WriteTo` (plain `io.Copy`, ~32 KB internal chunks) or `FileReader.WriteTo` (`pbm/backup/types.go:199`, `io.CopyBuffer` with the fs-configured buffer, 32 KiB–10 MiB normalized by `fs.go:101`).
- **Everything flows through one `io.Pipe` per file** (`UploadWithOpts`, storage.go:306). Pacing the reader/write side paces the whole stream.
- The fs backend is exact: throttling the source paces the file write 1:1.
- The S3 backend is average-exact: the multipart uploader buffers up to roughly `Concurrency × PartSize` (NumCPU/2 × 10 MB) in flight, so bursts can exceed the cap briefly; steady-state average tracks the reader pace. The report should state this behavior rather than claim a hard cap.
- MinIO-type storage currently uploads single-threaded (v2.12.0 release notes: known limitation), which interacts with throttling trivially.
- `golang.org/x/time/rate` is **already vendored** (`vendor/golang.org/x/time/rate`) — zero new dependency, zero `go.mod` churn. Caveat to remember: `Limiter.WaitN(ctx, n)` errors if `n > burst` (`rate.go:259`), so a chunked wrapper must split large writes into burst-sized waits (or set burst = copy-buffer size).

### Insertion point options (increasing invasiveness)

1. **Throttled `Source` wrapper (recommended PoC)** — in `writeFile`/`uploadFiles`, wrap the per-file `Source` so `WriteTo` counts every written chunk against a **shared** `*rate.Limiter` via `WaitN`. One limiter per backup per agent ⇒ all workers + journals share the cap. Touches only `pbm/backup/` — no storage backend changes, works identically for fs/S3/GCS/…, unit-testable with the existing `blackhole` storage.
2. **Storage `Option`** — add a `RateLimit` opt to `storage.Opts` (storage.go:114) and honor it per backend. More faithful ("limit the wire, not the read") but touches every backend and still can't cap in-flight multipart buffers.
3. **Uploader-level** (S3 only) — cap `u.Concurrency` / part timing per Nathan's 2021 suggestion; not a real rate limiter, S3-only, rejected as the main approach.

Option 1 also composes with the existing `numParallelFiles` worker pool and the errgroup context (cancellation propagates into `WaitN` automatically).

### Config plumbing — exact places to mirror (pattern: `numParallelFiles`)

| Layer | File | Existing pattern |
|---|---|---|
| Config struct | `pbm/config/config.go:547` (`BackupConf`) | `NumParallelFiles int` + `GetNumParallelFiles()` at :572 — add `RateLimitMBs int` + getter with default 0 = off |
| Config docs | `pbm list`/docs site file reference | mirrors `backup.numParallelFiles` |
| Command wire format | `pbm/ctrl/cmd.go:131` (`BackupCmd`) | `NumParallelFiles *int32` bson field — add `RateLimitMBs *int64,omitempty` |
| CLI flag | `cmd/pbm/main.go:312` | `--num-parallel-files` — add `--rate-limit-mb` (or similar) |
| CLI → cmd struct | `cmd/pbm/backup.go:44,106,161` | `parseCLINumParallelOption` |
| Agent apply | `cmd/pbm-agent/backup.go:132` | `bcp.SetNumParallelFiles(...)` — add `bcp.SetRateLimit(...)` |
| Backup object | `pbm/backup/backup.go:36,90` | `numParallelFiles` field + setter + `getNumParallelFiles()` |
| Enforcement | `pbm/backup/physical.go:527` (`uploadPhysical`) | create shared limiter once per replica-set backup; pass into `uploadFiles` → `writeFile` |

Config is stored cluster-wide in control collections (`pbm config --file=...`), and per-backup **profiles** exist (`GetProfiledConfig`, `BackupCmd.Profile`) — a natural place for per-profile rate limits later.

### Semantics: per what?

Each replica set's elected backup node performs its own upload (PBM picks a suitable node by priority; mixed deployments require PSMDB nodes). Therefore:

- A limiter constructed in the agent = **per uploading process (per node)** semantics — the natural MVP unit. Config is cluster-wide but enforcement is independent per uploading agent.
- A **deployment-wide** cap would require distributed coordination across agents through control collections (token sharing) — explicitly out of MVP scope; this is one of the "ask maintainers" questions, matching the user's own caveat (per process / per node / per deployment must not be assumed).
- In a sharded cluster, total egress = sum over shards + config server RS of per-agent caps. The report should say this plainly.

---

## 4. Current status — has anyone built it?

- **No throttling/rate-limit code exists on `main`** (grepped: no `rate.Limiter`, no throttle config anywhere outside vendored SDK internals). The `x/` pbm-x prototype copy of physical.go likewise has none.
- **Latest release v2.17.0 (Oct 15, 2026)** — release highlights are about physical PITR index replay, TTL monitor during restore, time-series fixes. No throttling. Repo is very active (merge commit on main Nov 23, 2026; recent PRs Nov 2026).
- Open PR list (through Nov 2026): nothing rate-limit related (unify restore cleanup, Go bump, OCI/Alloy settings, native PITR replay, Azure workflow identity, progress indicators, CSE, physical backup for Enterprise…).
- 2025 GSoC: the throttling idea had interested students (forum threads 36461, 36593, 36744) but no implementation landed.
- Percona's Jira (project PBM) is the bug/feature tracker (per repo AGENTS.md); it migrated to Atlassian (`perconadev.atlassian.net`) and no longer answers anonymous REST queries, so I could not enumerate internal tickets — **can't fully rule out an internal plan; ask maintainers** (that's the user's original caveat and it stands).

**Conclusion:** the feature is unclaimed, was offered twice (2025, 2026), the mentor is on record describing what a good result looks like, and Percona has publicly offered mentoring outside GSoC. A self-contained PoC + benchmark is both useful and timely. A PoC now exists on branch `physical-backup-rate-limit` — see `BENCHMARK.md`.

---

## 5. The benchmark / MVP — concrete plan grounded in the repo

### Environment (PBM already ships one)

`e2e-tests/` is a docker-compose harness that spins exactly what the MVP needs:

```sh
cd e2e-tests
MONGODB_VERSION=8.0 ./start-replset          # PSMDB 8.0 replica set + pbm-agent + MinIO storage
docker compose -f ./docker/docker-compose.yaml exec agent-rs101 \
    pbm config --file=/etc/pbm/minio.yaml   # wire PBM to MinIO
docker compose -f ./docker/docker-compose.yaml exec agent-rs101 pbm list
```

`./run-rs` runs the general/consistency e2e suite; `./run-all` is the heavy full pass. `MONGODB_VERSION` picks PSMDB version (default 8.0; physical needs ≥ 7.0). For a *network-bound* experiment, put MinIO on a separate host/container (or use a real S3 endpoint) and shape/measure the link — MinIO co-located on the same compose network makes "bandwidth" a loopback abstraction; state the topology honestly in the report. Optional third arm: OS-level shaping (`tc netem` / `trickle`, Nathan's own workaround) as an external baseline to compare the in-process limiter against.

### Repeatable dataset

Options, ranked:
1. **mgodatagen** — purpose-built MongoDB dataset generator (config-driven docs/size/indexes, still the standard for this).
2. **YCSB load phase** — `ycsb load mongodb -P workloads/workloada -p recordcount=… -p mongodb.url=…`; also doubles as the load generator (below).
3. **`pbm-speed-test`'s embedded dataset** (`cmd/pbm-speed-test/dataset.go`) — a real UK-restaurant JSON corpus; realistic docs but tiny (~250 B/doc); scale by record count only.

Target something that makes duration differences visible at MVP scale: e.g. 20–50 GB dbPath. WiredTiger compresses on disk; a 50 GB logical dataset may be smaller on disk — generate until `du` on dbPath hits the target, and record both numbers.

### Database load during backup (the "with load" arm)

- **YCSB** (`site.ycsb` / classic 0.17): workloads A (50/50 read/update) and B (read-mostly) are the standard; reports per-op p50/p95/p99 latencies + throughput directly. Run with `-target` to hold a fixed ops/s so backup-induced latency deltas are visible against a steady baseline.
- **Percona Load Generator for MongoDB (plgm)** — Percona's own tool (blog, Dec 18, 2025) that replays application-shaped workloads; the "house" choice, pairs well with a Percona-facing report.
- `mongosh` loop measuring insert/find latency percentiles is a fine lightweight fallback; `mongostat`/`mongotop` for coarse view; `db.serverStatus().metrics`/`opLatencies` for server-side numbers.

### Measurements (the table the mentor asked for)

| Measurement | No cap | With cap(s) | How |
|---|---|---|---|
| Backup duration | ✓ | ✓ | `pbm list` start/complete timestamps; `pbm logs` |
| Network throughput of the uploading agent | ✓ | ✓ | container NIC counters (`/proc/net/dev` in agent's netns, or docker stats / `nethogs`); verify cap accuracy (avg + burst) |
| DB request latency under load | ✓ | ✓ | YCSB p50/p95/p99 before/during/after; or plgm report |
| Resource use (CPU, disk I/O, RSS) | ✓ | ✓ | `pidstat`, `iostat` on agent + mongod; mongod WiredTiger cache stats |
| **dbPath growth (checkpoints held)** | ✓ | ✓ | `du` dbPath during backup window — *the hidden cost of a longer cursor-open window* |
| Restore validation | ✓ | ✓ | e2e suite / `pbm restore` once per config to prove the limiter didn't corrupt anything |

Run a **sweep**, not one cap: e.g. uncapped, 500 MB/s, 200 MB/s, 100 MB/s, 50 MB/s → produces the "user guide table" (rate setting → expected backup time → measured latency delta), anchored by the mentor's 24 h / 10 TB constraints (sanity floor ≈ 121 MB/s for 10 TB daily).

### Deliverable

Fork of PBM (branch naming per AGENTS.md: `PBM-XXXX-backup-rate-limit`, commits prefixed `PBM-XXXX.`) + this report with the table, plus a "how to parameterize" guide. File the Jira ticket first if Percona engages.

---

## 6. Repo contribution facts (from AGENTS.md / Makefile / CLAUDE.md)

- Builds: `make build` (`-mod=vendor -tags gssapi`; krb5-devel needed); `make test` = e2e; `go test ./...` = unit; `golangci-lint run` with strict config (lll, nonamedreturns, errname…).
- Use the project's `pbm/errors` wrapper, not stdlib errors. Tabs in Go.
- `x/` is the pbm-x experimental module — **no cross-imports between `pbm/` and `x/`**; target `pbm/` proper for this feature.
- Vendored deps — `go mod vendor` after touching go.mod (not needed here: `x/time/rate` already vendored).
- Bug tracker: Jira project **PBM** (jira.percona.com → perconadev.atlassian.net), not GitHub issues.
- Useful extras already in-repo: `pbm-speed-test` (streams a sample collection through compression into `blackhole` storage — a ready-made micro-bench for validating limiter behavior in isolation, no infra noise); `storage/blackhole` for unit tests.

---

## 7. Open design questions to put to maintainers (do not assume)

1. **Unit of the limit** — per uploading agent (MVP default), per node, or deployment-wide (needs distributed coordination)?
2. **Config surface** — `backup.rateLimit` global + per-profile? CLI `--rate-limit` per-run? Units: MB/s.
3. **Scope** — physical only (GSoC text says physical)? Also incremental physical? Oplog/PITR slicing streams? Restores (the inverse pain — restore saturates the network too)? Logical backups?
4. **Burst semantics** — average-rate with bounded bursts (S3 multipart reality) acceptable, or is a hard cap required (implies backend-level changes)?
5. **Interaction with `numParallelFiles`** — cap shared across workers (one limiter) vs per worker?
6. **Interaction with the checkpoint-retention window** — is there a max acceptable backup duration guidance per data size that should cap how low users may set the limiter (docs warn about dbPath growth)?
7. **Composability** — same wrapper reused for external backups / other storages without change (true for the Source-wrapper approach)?

---

## 8. Fit with pgvault (prior art on this machine)

`~/Projects/pg-vault` (pgvault: encrypted PostgreSQL backups) already contains the same pipeline shape:

- `internal/backup/manager.go:134` — `reader, writer := io.Pipe()` streaming `pg_dump` → compression → storage, no plaintext temp file.
- `internal/storage/s3.go` — the very same `aws-sdk-go-v2` `manager.Uploader` (multipart) that PBM's S3 backend uses.

So the core engineering pattern this project needs — streaming a database artifact through a pipe into a multipart cloud uploader, with Go, in a CLI tool — is already in hand. The new territory is: (a) the limiter itself (`x/time/rate` around an `io.WriterTo`), (b) MongoDB-side operational behavior (backup cursors, checkpoint retention, replica-set coordination), and (c) rigorous benchmarking under load.

---

## 9. Source index

- GSoC 2026 ideas (incl. Feb 18, 2026 "not accepted" update): https://forums.percona.com/t/google-summer-of-code-2026-project-ideas/40141
- GSoC 2025 ideas + mentor Q&A (24 h / 10 TB / table): https://forums.percona.com/t/36461 (post 6)
- 2021 throttling feature request: https://forums.percona.com/t/feature-request-throttling-support-for-s3-backups/8664
- PBM repo (main @ ae300e0f, Nov 23 2026): https://github.com/percona/percona-backup-mongodb · latest release v2.17.0 (Oct 15, 2026)
- Physical backups docs: https://docs.percona.com/percona-backup-mongodb/2.16.0/features/physical.html and …/usage/backup-physical.html (`numParallelFiles`)
- Physical backup internals blog (backup cursors, recovery timestamp): https://www.percona.com/blog/physical-backup-support-in-percona-backup-mongodb/
- e2e harness: `e2e-tests/README.md` (`start-replset`, `run-rs`, `MONGODB_VERSION`)
- Load tools: YCSB (mongodb binding, p50/95/99, `-target`), mgodatagen (dataset), plgm — Percona Load Generator for MongoDB (blog, Dec 18, 2025), POCDriver
- Rate limiting: `golang.org/x/time/rate` (vendored in-repo; `WaitN` fails when `n > burst`)
