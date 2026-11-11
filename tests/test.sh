#!/usr/bin/env bash
#
# tests/test.sh — vnstat·curl 을 가짜로 바꿔 check/report/status 동작을 확인합니다.
# 실행: bash tests/test.sh   (필요: bash, jq, awk)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/vnstat" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_VNSTAT_JSON"
EOF
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "CURL" >> "$FAKE_CURL_LOG"
if [[ " $* " == *" @- "* ]]; then cat >> "$FAKE_CURL_LOG"; fi
EOF
chmod +x "$T/bin/"*

export PATH="$T/bin:$PATH" FAKE_VNSTAT_JSON="$T/vnstat.json" FAKE_CURL_LOG="$T/curl.log" OCI_TRAFFIC_CONF="$T/conf"
cat > "$T/conf" <<EOF
IFACE=eth0
WEBHOOK_URL=http://example.invalid/hook
LIMIT_GB=100
ALERT_PCTS="50 80"
STATE_DIR=$T/state
HOST_LABEL=test
EOF
: > "$FAKE_CURL_LOG"

Y=$(date +%Y); M=$((10#$(date +%m))); D=$((10#$(date +%d)))
# usage <이번 달 송신 바이트> [연] [월] [jsonversion]
usage() {
  local y="${2:-$Y}" m="${3:-$M}" v="${4:-2}"
  cat > "$FAKE_VNSTAT_JSON" <<EOF
{"jsonversion":"$v","interfaces":[{"name":"eth0","traffic":{
"day":[{"date":{"year":$y,"month":$m,"day":$D},"rx":0,"tx":1000}],
"month":[{"date":{"year":$y,"month":$m},"rx":0,"tx":$1}]}}]}
EOF
}
run() { bash "$ROOT/oci-free-traffic-alert.sh" "$@"; }
sent() { grep -c '^CURL' "$FAKE_CURL_LOG" || true; }
fail=0
expect() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1 (기대 $3, 실제 $2)"; fail=1; fi; }

usage 40000000000; run check >/dev/null
expect "40%: 알림 없음" "$(sent)" 0
usage 55000000000; run check >/dev/null
expect "55%: 50% 알림 1건" "$(sent)" 1
run check >/dev/null
expect "55% 재실행: 중복 알림 없음" "$(sent)" 1
usage 85000000000; run check >/dev/null
expect "85%: 80% 알림 추가" "$(sent)" 2
expect "80% 알림 문구" "$(grep -c '무료 한도의 80%' "$FAKE_CURL_LOG")" 1

echo "2000-01 80" > "$T/state/state"; usage 55000000000; run check >/dev/null
expect "새 달: 상태 초기화 후 다시 알림" "$(sent)" 3

usage 90000000000 2000 1
expect "지난달 항목만 있으면 이번 달은 0" "$(run status | grep -c '(0.00%)')" 1

usage 55000000000; run report >/dev/null
expect "report 전송" "$(sent)" 4

usage 1 "$Y" "$M" 1
run check >/dev/null 2>&1 && st=0 || st=$?
expect "vnstat 1.x JSON 거부" "$st" 1

sed -i '/WEBHOOK_URL/d' "$T/conf"; rm -f "$T/state/state"; usage 55000000000
run check >/dev/null 2>&1 && st=0 || st=$?
expect "채널 없음: 실패" "$st" 1
expect "채널 없음: 상태 미기록" "$([[ -f "$T/state/state" ]] && echo 있음 || echo 없음)" 없음

run bogus >/dev/null 2>&1 && st=0 || st=$?
expect "잘못된 명령: 사용법 안내" "$st" 2

exit "$fail"
