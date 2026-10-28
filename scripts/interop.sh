#!/bin/sh
# raydns against dig: a fresh server on random high ports, instances registered over HTTP, and
# every answer form checked with a real resolver tool: A/AAAA, tags, SRV with additional
# addresses, CNAME, the apex, NXDOMAIN, REFUSED, truncation and the TCP retry, case echo,
# a lease running out. Usage: scripts/interop.sh   (needs ./raydns: make build)
set -eu
BIN="$(cd "$(dirname "$0")/.." && pwd)/raydns"
command -v dig >/dev/null || { echo "interop: needs dig" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/raydns-interop.XXXXXX")"
DP=$((30000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
HP=$((40000 + $(od -An -N2 -tu2 /dev/urandom) % 10000))
cat >"$WORK/raydns.toml" <<EOF
[server]
dns = "127.0.0.1:$DP"
http = "127.0.0.1:$HP"
state = "$WORK/state.json"

[[record]]
name = "www"
type = "CNAME"
value = "web.service.ray.internal"

[[record]]
name = "@"
type = "TXT"
value = "v=spf1 -all"
EOF
"$BIN" serve --config "$WORK/raydns.toml" >"$WORK/serve.log" 2>&1 &
SRV=$!
trap 'kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; rm -rf "$WORK"' EXIT
API="http://127.0.0.1:$HP"
i=0
until curl -s -o /dev/null "$API/v1/health"; do
    i=$((i + 1)); [ $i -gt 50 ] && { cat "$WORK/serve.log"; exit 1; }
    sleep 0.1
done
reg() { curl -sf -o /dev/null -X PUT "$API/v1/services/$1" -d "$2"; }
reg web/w1 '{"address":"10.0.0.1","port":8080,"tags":["v1"]}'
reg web/w2 '{"address":"10.0.0.2","port":8081,"tags":["v2"]}'
reg web/w6 '{"address":"fd00::6","port":8082}'
n=1; while [ $n -le 80 ]; do reg "big/b$n" "{\"address\":\"10.1.0.$n\",\"port\":9000}"; n=$((n + 1)); done

D() { dig @127.0.0.1 -p "$DP" +norecurse +time=2 +tries=1 "$@"; }
pass=0
expect() { # expect NAME WANT GOT
    if [ "$2" = "$3" ]; then pass=$((pass + 1)); printf "  ok    %s\n" "$1"
    else printf "  FAIL  %s\n        want: %s\n        got:  %s\n" "$1" "$2" "$3"; exit 1; fi
}
line() { tr '\n' ' ' | sed 's/ $//'; }

echo "raydns interop with $(dig -v 2>&1 | head -1) on udp+tcp 127.0.0.1:$DP"
expect "A, sorted" "10.0.0.1 10.0.0.2" "$(D web.service.ray.internal +short | sort | line)"
expect "authoritative, EDNS 1232" "qr aa 1232" "$(D web.service.ray.internal | awk '/^;; flags:/{f=$3" "$4} /udp:/{u=$NF} END{print f" "u}' | tr -d ';')"
expect "AAAA" "fd00::6" "$(D web.service.ray.internal AAAA +short)"
expect "tag filter" "10.0.0.2" "$(D v2.web.service.ray.internal +short)"
expect "SRV" "8080 8081 8082" "$(D _web._tcp.service.ray.internal SRV +short | awk '{print $3}' | sort | line)"
expect "SRV additional: 3 addresses + OPT" "4" "$(D _web._tcp.service.ray.internal SRV | awk '/^;; flags:/{print $NF}')"
expect "instance name" "10.0.0.2" "$(D w2.web.instance.ray.internal +short)"
expect "CNAME followed in the zone" "10.0.0.1 10.0.0.2 web.service.ray.internal." "$(D www.ray.internal +short | sort | line)"
expect "apex TXT" '"v=spf1 -all"' "$(D ray.internal TXT +short)"
expect "apex NS" "ns.ray.internal." "$(D ray.internal NS +short)"
expect "ns address" "127.0.0.1" "$(D ns.ray.internal +short)"
expect "NXDOMAIN with SOA" "NXDOMAIN SOA" "$(D nope.service.ray.internal | awk '/status:/{s=$6} /IN[ \t]+SOA/{t="SOA"} END{print s" "t}' | tr -d ',')"
expect "outside the zone" "REFUSED" "$(D example.com | awk '/status:/{print $6}' | tr -d ',')"
expect "case echoed" "WeB.SeRvIcE.rAy.InTeRnAl." "$(D WeB.SeRvIcE.rAy.InTeRnAl | awk '/^WeB/{print $1; exit}')"
expect "truncated without EDNS" "tc" "$(D big.service.ray.internal +noedns +ignore | awk '/^;; flags:/{print $5}' | tr -d ';')"
expect "dig retries over TCP" "80" "$(D big.service.ray.internal +noedns +short | wc -l | tr -d ' ')"
expect "80 fit in 1232 with EDNS" "80" "$(D big.service.ray.internal +short | wc -l | tr -d ' ')"
reg web/w9 '{"address":"10.0.0.9","port":80,"ttl":"1s"}'
expect "a lease, live" "10.0.0.1 10.0.0.2 10.0.0.9" "$(D web.service.ray.internal +short | sort | line)"
sleep 1.5
expect "a lease, run out" "10.0.0.1 10.0.0.2" "$(D web.service.ray.internal +short | sort | line)"
curl -sf -o /dev/null -X DELETE "$API/v1/services/web/w1"
expect "deregistered" "10.0.0.2" "$(D web.service.ray.internal +short | sort | line)"
echo "$pass checks passed"
