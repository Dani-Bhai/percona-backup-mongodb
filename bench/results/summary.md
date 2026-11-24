# PBM physical backup rate-limit benchmark

Baseline (no backup): p95=4.05 ms, p99=7.12 ms, p99 max=10.82 ms, ~645 ops/s

| Cap (MiB/s) | Backup (MiB) | Duration (s) | Upload phase (s) | Upload (MiB/s) | Wire on lo (MiB/s) | DB p95 med (ms) | DB p99 med (ms) | DB p99 max (ms) | Ops/s | dbPath growth (MiB) |
|---|---|---|---|---|---|---|---|---|---|---|
| none | 645.7 | 23.11 | 17 | 38.0 | 28.2 | 25.29 | 47.31 | 1451.14 | 157 | 200.2 |
| 20 | 645.6 | 40.08 | 35 | 18.4 | 16.5 | 8.80 | 12.66 | 23.32 | 315 | 200.2 |
| 10 | 636.4 | 75.08 | 69 | 9.2 | 8.7 | 13.76 | 18.53 | 486.32 | 281 | 200.3 |

## Agent resource use

| Cap (MiB/s) | Agent CPU (% of one core) | Agent max RSS (MiB) |
|---|---|---|
| none | 26.9 | 186.4 |
| 20 | 30.7 | 114.6 |
| 10 | 16.2 | 120.1 |
