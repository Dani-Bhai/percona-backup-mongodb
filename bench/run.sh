#!/usr/bin/env bash
# Runs the PBM physical backup rate-limit benchmark.
#
# The dataset is sized by its on-disk footprint (SEED_TARGET_MB), not by
# document count, so it stays within the disk budget available on this host.
# Results are written to bench/results/.
#
# Usage:
#   ./run.sh                 # default: 1.5 GiB dataset, caps 0/20/10 MiB/s
#   SEED_TARGET_MB=800 ./run.sh
#   CAPS="0 10 5" ./run.sh

set -euo pipefail

BENCH_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
export BENCH_DIR
export BENCH_UID=$(id -u)
export BENCH_GID=$(id -g)

PBM_DIR=$(cd "${BENCH_DIR}/.." && pwd)
RESULTS="${BENCH_DIR}/results"
DATA="${BENCH_DIR}/data"
COMPOSE="${BENCH_DIR}/docker-compose.yaml"
PBM_URI="mongodb://127.0.0.1:27018/?directConnection=true"
export PBM_MONGODB_URI="${PBM_URI}"

SEED_TARGET_MB="${SEED_TARGET_MB:-1500}"
LOAD_SECONDS="${LOAD_SECONDS:-900}"
CAPS="${CAPS:-0 20 10}"
export LOAD_SECONDS

mkdir -p "${RESULTS}" "${DATA}/db" "${DATA}/minio"

log() { printf '\n=== %s ===\n' "$*"; }

cleanup() {
    docker ps -q --filter "label=com.docker.compose.service=loadgen" | xargs -r docker rm -f >/dev/null 2>&1 || true
    for f in load collect agent; do
        if [[ -f "${RESULTS}/${f}.pid" ]]; then
            kill "$(cat "${RESULTS}/${f}.pid")" >/dev/null 2>&1 || true
            rm -f "${RESULTS}/${f}.pid"
        fi
    done
}
trap cleanup EXIT

restart_mongod() {
    docker compose -f "${COMPOSE}" restart mongod >/dev/null
    for _ in $(seq 1 60); do
        if docker compose -f "${COMPOSE}" exec -T -e HOME=/tmp mongod \
            mongosh --port 27018 --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
            sleep 2
            return 0
        fi
        sleep 1
    done
    echo "mongod did not become primary after restart" >&2
    return 1
}

log "building pbm"
make -C "${PBM_DIR}" build

log "starting mongod and minio"
docker compose -f "${COMPOSE}" up -d mongod minio

log "waiting for minio"
for _ in $(seq 1 60); do
    if curl -sf http://127.0.0.1:9000/minio/health/live >/dev/null; then
        break
    fi
    sleep 1
done

log "creating bucket"
docker compose -f "${COMPOSE}" run --rm createbucket

log "waiting for mongod"
for _ in $(seq 1 60); do
    if docker compose -f "${COMPOSE}" exec -T -e HOME=/tmp mongod \
        mongosh --port 27018 --quiet --eval 'db.adminCommand({ping: 1}).ok' >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

log "initiating replica set"
docker compose -f "${COMPOSE}" exec -T -e HOME=/tmp mongod mongosh --port 27018 --quiet --eval '
    try {
        rs.status();
    } catch (e) {
        rs.initiate({_id: "rs0", members: [{_id: 0, host: "127.0.0.1:27018"}]});
    }
' || true

for _ in $(seq 1 60); do
    if docker compose -f "${COMPOSE}" exec -T -e HOME=/tmp mongod \
        mongosh --port 27018 --quiet --eval 'db.hello().isWritablePrimary' 2>/dev/null | grep -q true; then
        break
    fi
    sleep 1
done

log "seeding dataset (target ${SEED_TARGET_MB} MiB on disk)"
docker compose -f "${COMPOSE}" exec -T -e HOME=/tmp -e SEED_TARGET_MB="${SEED_TARGET_MB}" mongod \
    mongosh --port 27018 --quiet --file /scripts/seed.js

log "starting pbm-agent"
"${PBM_DIR}/bin/pbm-agent" > "${RESULTS}/agent.log" 2>&1 &
echo $! > "${RESULTS}/agent.pid"
sleep 3

log "configuring pbm"
"${PBM_DIR}/bin/pbm" config --file "${BENCH_DIR}/pbm-s3.yaml"
"${PBM_DIR}/bin/pbm" status > "${RESULTS}/status-before.txt" 2>&1 || true

log "warmup backup (not measured)"
warmup_out=$("${PBM_DIR}/bin/pbm" backup --type=physical --compression=none --wait)
printf '%s\n' "${warmup_out}"
warmup_name=$(printf '%s\n' "${warmup_out}" | sed -n 's/^Backup "\([^"]*\)" saved.*/\1/p' | tail -1)
if [[ -z "${warmup_name}" ]]; then
    echo "failed to determine the warmup backup name" >&2
    exit 1
fi
"${PBM_DIR}/bin/pbm" delete-backup -y "${warmup_name}" >/dev/null
restart_mongod

log "starting database load"
docker compose -f "${COMPOSE}" run --rm -T loadgen \
    > "${RESULTS}/load.jsonl" 2> "${RESULTS}/load.err" &
echo $! > "${RESULTS}/load.pid"

# Let the load generator warm up so the baseline window is clean.
sleep 25

log "starting metrics collector"
"${BENCH_DIR}/scripts/collect.sh" \
    "${RESULTS}/metrics.tsv" "$(cat "${RESULTS}/agent.pid")" "${DATA}/db" "$((LOAD_SECONDS + 60))" &
echo $! > "${RESULTS}/collect.pid"

: > "${RESULTS}/runs.tsv"

for cap in ${CAPS}; do
    args=(backup --type=physical --compression=none --wait --wait-time 30m)
    if [[ "${cap}" != "0" ]]; then
        args+=(--rate-limit-mb "${cap}")
    fi

    # Warm up with the same cap so the measured run starts from a settled
    # checkpoint/oplog state. Discard the warmup backup.
    log "warmup backup with cap=${cap} MB/s (not measured)"
    warm_out=$("${PBM_DIR}/bin/pbm" "${args[@]}")
    warm_name=$(printf '%s\n' "${warm_out}" | sed -n 's/^Backup "\([^"]*\)" saved.*/\1/p' | tail -1)
    if [[ -z "${warm_name}" ]]; then
        echo "failed to determine the warmup backup name" >&2
        exit 1
    fi
    "${PBM_DIR}/bin/pbm" delete-backup -y "${warm_name}" >/dev/null

    # A clean restart releases checkpoints retained during the warmup, so
    # every measured run starts from the same dbPath size.
    restart_mongod

    log "backup with cap=${cap} MB/s"
    start=$(date +%s%3N)
    out=$("${PBM_DIR}/bin/pbm" "${args[@]}")
    end=$(date +%s%3N)
    printf '%s\n' "${out}"

    name=$(printf '%s\n' "${out}" | sed -n 's/^Backup "\([^"]*\)" saved.*/\1/p' | tail -1)
    if [[ -z "${name}" ]]; then
        echo "failed to determine the backup name" >&2
        exit 1
    fi

    "${PBM_DIR}/bin/pbm" describe-backup "${name}" -o json > "${RESULTS}/backup-${cap}.json"
    size=$(jq -r '.size // 0' "${RESULTS}/backup-${cap}.json")
    size_uncompressed=$(jq -r '.size_uncompressed // 0' "${RESULTS}/backup-${cap}.json")
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "${cap}" "${name}" "${start}" "${end}" "${size}" "${size_uncompressed}" \
        >> "${RESULTS}/runs.tsv"

    "${PBM_DIR}/bin/pbm" delete-backup -y "${name}" >/dev/null
    sleep 3
done

cleanup
trap - EXIT

log "analyzing results"
python3 "${BENCH_DIR}/scripts/analyze.py"

log "stopping containers"
docker compose -f "${COMPOSE}" stop mongod minio

# MinIO keeps unfinished multipart uploads in .minio.sys/tmp; drop them so
# repeated sweeps do not accumulate disk usage.
rm -rf "${DATA}/minio/.minio.sys/tmp"

log "done: see ${RESULTS}/summary.md"
