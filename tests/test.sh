#!/usr/bin/env bash
#
# tests/test.sh — vnstat·curl 을 가짜로 바꿔 check/report/status 동작을 확인합니다.
# 실행: bash tests/test.sh   (필요: bash, jq, awk, GNU date)
#
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/vnstat" <<'EOF'
#!/usr/bin/env bash
cat "$FAKE_VNSTAT_JSON"
EOF
# 가짜 curl: 채널별로 호출을 기록. FAIL_TELEGRAM=1 이면 텔레그램 전송만 실패.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
if [[ "$*" == *api.telegram.org* ]]; then
  [[ "${FAIL_TELEGRAM:-0}" == 1 ]] && exit 22
  echo "CURL telegram" >> "$FAKE_CURL_LOG"
else
  echo "CURL webhook" >> "$FAKE_CURL_LOG"
  cat >> "$FAKE_CURL_LOG"
fi
EOF
chmod +x "$T/bin/"*

# 기준일 2026-11-11 고정 (11월은 30일 → 남은 일수 19)
export PATH="$T/bin:$PATH" FAKE_VNSTAT_JSON="$T/vnstat.json" FAKE_CURL_LOG="$T/curl.log" \
       OCI_TRAFFIC_CONF="$T/conf" OCI_TRAFFIC_TODAY=2026-11-11
cat > "$T/conf" <<EOF
IFACE=eth0
WEBHOOK_URL=http://example.invalid/hook
LIMIT_GB=100
ALERT_PCTS="50 80"
STATE_DIR=$T/state
HOST_LABEL=test
EOF
: > "$FAKE_CURL_LOG"

# fixture <이번 달 송신> [오늘 송신] [11/4~11/10 하루 송신 (비우면 이력 없음)] [jsonversion] [월(YYYY-MM)]
# 이력이 있으면 7일 범위 밖인 11/3 에 큰 값을 넣어, 범위 계산이 틀리면 평균이 깨지게 한다.
fixture() {
  local mtx=$1 dtx=${2:-1000} hist=${3:-} v=${4:-2} ym=${5:-2026-11} d
  local days="{\"date\":{\"year\":2026,\"month\":11,\"day\":11},\"rx\":2000,\"tx\":$dtx}"
  if [[ -n "$hist" ]]; then
    days+=",{\"date\":{\"year\":2026,\"month\":11,\"day\":3},\"rx\":0,\"tx\":999000000000}"
    for d in 4 5 6 7 8 9 10; do days+=",{\"date\":{\"year\":2026,\"month\":11,\"day\":$d},\"rx\":0,\"tx\":$hist}"; done
  fi
  echo "{\"jsonversion\":\"$v\",\"interfaces\":[{\"traffic\":{\"day\":[$days],
\"month\":[{\"date\":{\"year\":${ym%-*},\"month\":$((10#${ym#*-}))},\"rx\":3000,\"tx\":$mtx}]}}]}" > "$FAKE_VNSTAT_JSON"
}
run() { bash "$ROOT/oci-free-traffic-alert.sh" "$@"; }
sent() { grep -c "^CURL ${1:-}" "$FAKE_CURL_LOG" || true; }
has() { run status | grep -cF -- "$1" || true; }
fail=0
expect() { if [[ "$2" == "$3" ]]; then echo "ok   - $1"; else echo "FAIL - $1 (기대 $3, 실제 $2)"; fail=1; fi; }

# ── 임계치 알림 ──
fixture 40000000000; run check >/dev/null
expect "40%: 알림 없음" "$(sent)" 0
fixture 55000000000; run check >/dev/null
expect "55%: 50% 알림 1건" "$(sent)" 1
run check >/dev/null
expect "55% 재실행: 중복 알림 없음" "$(sent)" 1
fixture 85000000000; run check >/dev/null
expect "85%: 80% 알림 추가" "$(sent)" 2
expect "80% 알림 문구" "$(grep -c '무료 한도의 80%' "$FAKE_CURL_LOG")" 1
echo "2000-01 080" > "$T/state/level.webhook"; fixture 55000000000; run check >/dev/null
expect "새 달: 다시 알림" "$(sent)" 3

# ── 리포트 ──
fixture 90000000000 1000 "" 2 2026-10
expect "지난달 항목만 있으면 이번 달은 0" "$(has '무료 한도 사용률: 0.00%')" 1
fixture 55000000000; run report >/dev/null
expect "report 전송" "$(sent)" 4

# ── 급증 알림 ──
fixture 55000000000 20000000000 1000000000; run check >/dev/null
expect "급증(평균 1GB, 오늘 20GB): 알림 1건" "$(sent)" 5
expect "급증 문구(20배)" "$(grep -c '평균의 20.0배' "$FAKE_CURL_LOG")" 1
run check >/dev/null
expect "급증: 같은 날 중복 없음" "$(sent)" 5
rm -f "$T/state/spike."*; fixture 55000000000 5000000000 100000000; run check >/dev/null
expect "급증: 10GB 미만이면 무시" "$(sent)" 5
rm -f "$T/state/spike."*; fixture 55000000000 10000000000 0; run check >/dev/null
expect "급증: 7일 송신 0 이고 오늘 10GB 면 알림" "$(sent)" 6
expect "급증: 평균 0 이면 배수 대신 송신량 표시" "$(grep -c '최근 7일 송신이 없었는데 오늘 10.00 GB' "$FAKE_CURL_LOG")" 1
rm -f "$T/state/spike."*; fixture 55000000000 20000000000; run check >/dev/null
expect "급증: 이력이 전혀 없으면 판단 안 함" "$(sent)" 6

# ── 분석 문구 (누적 10GB, 오늘 2GB, 11/4~10 매일 5GB) ──
fixture 10000000000 2000000000 5000000000
expect "월말 예상 = 누적 + 7일 평균 × 남은 19일" "$(has '월말 예상 송신: 105.00 GB (105.00%)')" 1
expect "7일 평균은 11/4~10만" "$(has '최근 7일 평균: 5.00 GB/일')" 1
expect "전일 대비" "$(has '전일 대비: -60% (어제 5.00 GB)')" 1
expect "월말 초과 경고" "$(has '이 추세면 월말에 무료 한도를 넘습니다')" 1
expect "남은 한도" "$(has '남은 송신 한도: 약 90.00 GB')" 1
fixture 5000000000 1000 5000000000
expect "월말 예상이 한도와 같으면 (100%)" "$(has '월말 예상 송신: 100.00 GB (100.00%)')" 1
expect "  초과 경고 없음" "$(has '이 추세면')" 0
fixture 10000000000
expect "이력 없음: 일평균으로 월말 예상" "$(has '월말 예상 송신: 27.27 GB')" 1
expect "이력 없음: 7일 평균 수집 중" "$(has '최근 7일 평균: 데이터 수집 중')" 1
expect "이력 없음: 전일 대비 수집 중" "$(has '전일 대비: 데이터 수집 중')" 1
expect "이상 없으면 정상" "$(has '✅ 상태: 정상')" 1

# ── 채널 일부 실패: 성공한 채널엔 다시 안 보내고 실패한 채널만 재시도 ──
rm -rf "$T/state"; : > "$FAKE_CURL_LOG"
printf 'TELEGRAM_BOT_TOKEN=x\nTELEGRAM_CHAT_ID=1\n' >> "$T/conf"
fixture 55000000000
FAIL_TELEGRAM=1 run check >/dev/null 2>&1 && st=0 || st=$?
expect "텔레그램 실패: 종료 코드 1" "$st" 1
expect "  웹훅은 전송" "$(sent webhook)" 1
FAIL_TELEGRAM=1 run check >/dev/null 2>&1 || true
expect "  재실행해도 웹훅 중복 없음" "$(sent webhook)" 1
run check >/dev/null
expect "  텔레그램 복구 후 텔레그램만 전송" "$(sent telegram) $(sent webhook)" "1 1"
run check >/dev/null
expect "  그다음엔 둘 다 중복 없음" "$(sent telegram) $(sent webhook)" "1 1"

# ── 오류 처리 ──
fixture 1 1000 "" 1
run check >/dev/null 2>&1 && st=0 || st=$?
expect "vnstat 1.x JSON 거부" "$st" 1
sed -i '/WEBHOOK_URL/d; /TELEGRAM/d' "$T/conf"; rm -rf "$T/state"; fixture 55000000000
run check >/dev/null 2>&1 && st=0 || st=$?
expect "채널 없음: 실패" "$st" 1
expect "채널 없음: 상태 미기록" "$(ls "$T/state" 2>/dev/null | grep -c '^level' || true)" 0
run bogus >/dev/null 2>&1 && st=0 || st=$?
expect "잘못된 명령: 사용법 안내" "$st" 2

exit "$fail"
