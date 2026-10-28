#!/bin/sh
# raydns under load: for each number of UDP receivers, a fresh raydns on random high ports with
# three instances of one service, then `raydns bench` from another process (closed loop, CLIENTS
# fibers). Usage: scripts/bench.sh [RECEIVERS...]   (needs ./raydns: make build)
set -eu
RS="${*:-1 2 4 8}"
BIN="$(cd "$(dirname "$0")/.." && pwd)/raydns"
N="${N:-200000}"
CLIENTS="${CLIENTS:-16}"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/raydns-bench.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for r in $RS; do
    DP=$((30000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
    HP=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
    cat >"$WORK/raydns.toml" <<EOF
[server]
dns = "127.0.0.1:$DP"
http = "127.0.0.1:$HP"
state = ""
receivers = $r
EOF
    "$BIN" serve --config "$WORK/raydns.toml" >"$WORK/serve.log" 2>&1 &
    SRV=$!
    i=0
    until curl -s -o /dev/null "http://127.0.0.1:$HP/v1/health"; do
        i=$((i + 1)); [ $i -gt 50 ] && { cat "$WORK/serve.log"; kill "$SRV"; exit 1; }
        sleep 0.1
    done
    for n in 1 2 3; do
        curl -s -o /dev/null -X PUT "http://127.0.0.1:$HP/v1/services/api/a$n" -d "{\"address\":\"10.0.0.$n\",\"port\":8080}"
    done
    out=$("$BIN" bench "127.0.0.1:$DP" api.service.ray.internal -n "$N" -c "$CLIENTS")
    rss=$(ps -o rss= -p "$SRV" | tr -d ' ')
    kill -TERM "$SRV"; wait "$SRV" || true
    printf "receivers %-2s  %s, server RSS %s MiB\n" "$r" "$out" "$((rss / 1024))"
done
