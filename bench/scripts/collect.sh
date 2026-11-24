#!/usr/bin/env bash
# Samples dbPath size, loopback network throughput, and pbm-agent CPU/RSS.
# Usage: collect.sh <out.tsv> <agent_pid> <dbpath> <duration_seconds>

set -u

out=$1
pid=$2
dbpath=$3
duration=$4

end=$(( $(date +%s) + duration ))

printf 'ts\tdbpath_bytes\tlo_rx_bytes\tagent_ticks\tagent_rss_kb\n' > "$out"

while [ "$(date +%s)" -lt "$end" ]; do
    ts=$(date +%s%3N)
    dbpath_bytes=$(du -sb "$dbpath" | cut -f1)
    lo_rx_bytes=$(awk '/^ *lo:/ {print $2}' /proc/net/dev)

    agent_ticks=0
    agent_rss_kb=0
    if [ -r "/proc/$pid/stat" ]; then
        agent_ticks=$(awk '{print $14 + $15}' "/proc/$pid/stat")
        agent_rss_kb=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status")
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
        "$ts" "$dbpath_bytes" "$lo_rx_bytes" "$agent_ticks" "$agent_rss_kb" >> "$out"

    sleep 0.5
done
