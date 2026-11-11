#!/usr/bin/env bash
#
# oci-free-traffic-alert — OCI 무료 송신(egress) 한도 대비 이번 달 사용량을 알림으로 보냅니다.
#
#   check   이번 달 송신량이 ALERT_PCTS 의 새 임계치를 넘었을 때만 알림 (cron: 10분마다)
#   report  사용량 요약 1건 전송 (cron: 하루 1번)
#   status  전송 없이 사용량만 출력
#
# 데이터: vnstat 2.x. NIC 를 지난 바이트를 모두 세므로 OCI 내부 무료 트래픽도 포함돼
#         실제 과금량보다 크게 잡힙니다(경고용으로는 안전한 쪽).
# 설정:   /etc/oci-free-traffic-alert.conf (환경변수 OCI_TRAFFIC_CONF 로 경로 변경 가능)
#
set -euo pipefail

CMD="${1:-}"
[[ "$CMD" =~ ^(check|report|status)$ ]] || { echo "사용법: $(basename "$0") check|report|status" >&2; exit 2; }

CONF="${OCI_TRAFFIC_CONF:-/etc/oci-free-traffic-alert.conf}"
if [[ -f "$CONF" ]]; then set -a; . "$CONF"; set +a; fi

IFACE="${IFACE:-$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' || true)}"
LIMIT_GB="${LIMIT_GB:-10000}"           # OCI 무료 송신 월 10TB (1TB=1000GB 로 잡아 조금 일찍 경고)
ALERT_PCTS="${ALERT_PCTS:-50 80 95}"
STATE_DIR="${STATE_DIR:-/var/lib/oci-free-traffic-alert}"
HOST_LABEL="${HOST_LABEL:-$(hostname)}"

die() { echo "❌ $*" >&2; exit 1; }

[[ -n "$IFACE" ]] || die "네트워크 인터페이스를 찾지 못했습니다. $CONF 에 IFACE 를 지정하세요."

# ── 사용량 읽기: 이번 달·오늘 항목을 날짜로 골라냄 ──────────────────────
# 마지막 항목([-1])을 쓰면 새 달 첫 기록 전에는 지난달 값을 읽게 되므로 날짜로 매칭한다.
JSON=$(vnstat -i "$IFACE" --json) \
  || die "vnstat 조회 실패: '$IFACE' 가 등록돼 있는지 확인하세요 (sudo vnstat --add -i $IFACE)"
USAGE=$(jq -er --argjson y "$(date +%Y)" --argjson m "$((10#$(date +%m)))" --argjson d "$((10#$(date +%d)))" '
  if (.jsonversion | tostring) != "2" then error("vnstat 2.x 가 필요합니다") else . end
  | .interfaces[0].traffic as $t
  | ([$t.month[]? | select(.date.year == $y and .date.month == $m)] | first // {}) as $mon
  | ([$t.day[]? | select(.date.year == $y and .date.month == $m and .date.day == $d)] | first // {}) as $day
  | "\($mon.tx // 0) \($mon.rx // 0) \($day.tx // 0)"' <<<"$JSON") || die "vnstat JSON 해석 실패"
read -r MONTH_TX MONTH_RX DAY_TX <<<"$USAGE"

PCT=$(awk -v b="$MONTH_TX" -v l="$LIMIT_GB" 'BEGIN { printf "%.2f", b / (l * 1e9) * 100 }')
size() { awk -v b="$1" 'BEGIN { if (b < 1e9) printf "%.1f MB", b / 1e6; else printf "%.2f GB", b / 1e9 }'; }

# 지금 넘어선 임계치 중 가장 큰 값 (없으면 0)
LEVEL=0
for p in $ALERT_PCTS; do
  if awk -v a="$PCT" -v p="$p" 'BEGIN { exit !(a >= p) }' && (( p > LEVEL )); then LEVEL=$p; fi
done

summary() {
  printf '%s\n' \
    "• 이번 달 송신: $(size "$MONTH_TX") / ${LIMIT_GB} GB (${PCT}%)" \
    "• 오늘 송신: $(size "$DAY_TX")" \
    "• 이번 달 수신: $(size "$MONTH_RX") (무료)"
}

# 설정된 채널(텔레그램·웹훅) 모두로 전송. 하나라도 실패하면 실패.
notify() {
  local text="$1" sent=0
  if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
    curl -fsS --max-time 15 -o /dev/null "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${text}" || return 1
    sent=1
  fi
  if [[ -n "${WEBHOOK_URL:-}" ]]; then
    jq -n --arg t "$text" '{text: $t}' \
      | curl -fsS --max-time 15 -o /dev/null -H 'Content-Type: application/json' -d @- "$WEBHOOK_URL" || return 1
    sent=1
  fi
  (( sent )) || { echo "알림 채널이 없습니다: $CONF 에 TELEGRAM_BOT_TOKEN·TELEGRAM_CHAT_ID 또는 WEBHOOK_URL 을 입력하세요" >&2; return 1; }
}

case "$CMD" in
  status)
    echo "[$HOST_LABEL] 인터페이스 $IFACE · 임계치 $ALERT_PCTS (%)"
    summary
    ;;
  report)
    if (( LEVEL > 0 )); then st="⚠️ 무료 한도의 ${LEVEL}% 이상 사용"; else st="✅ 정상"; fi
    notify "📊 OCI 송신 트래픽 리포트 [$HOST_LABEL]
$(summary)
상태: $st" || die "알림 전송 실패"
    echo "[$(date '+%F %T')] report sent (${PCT}%)"
    ;;
  check)
    state="$STATE_DIR/state" month=$(date +%Y-%m) prev_month="" prev_level=0
    if [[ -f "$state" ]]; then read -r prev_month prev_level < "$state" || true; fi
    [[ "$prev_month" == "$month" ]] || prev_level=0   # 달이 바뀌면 처음부터 다시 알림
    if (( LEVEL > prev_level )); then
      mkdir -p "$STATE_DIR"
      notify "🚨 OCI 송신 트래픽 경고 [$HOST_LABEL]
이번 달 송신량이 무료 한도의 ${LEVEL}%를 넘었습니다.
$(summary)
PAYG 계정은 무료 한도를 넘는 송신량부터 과금됩니다." || die "알림 전송 실패 — 다음 실행 때 다시 시도합니다"
      echo "$month $LEVEL" > "$state"
      echo "[$(date '+%F %T')] alert sent (${LEVEL}% 임계치, 현재 ${PCT}%)"
    fi
    ;;
esac
