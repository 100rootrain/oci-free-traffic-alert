#!/usr/bin/env bash
#
# oci-free-traffic-alert — OCI 무료 송신(egress) 한도 대비 이번 달 사용량을 알림으로 보냅니다.
#
#   check   (cron 10분마다) 이번 달 송신량이 ALERT_PCTS 의 새 임계치를 넘거나 오늘 송신이 급증하면 알림
#   report  (cron 하루 1번) 오늘·이번 달 사용량과 월말 예상·7일 평균·전일 대비 리포트 전송
#   status  전송 없이 리포트 내용만 출력
#
# 데이터: vnstat 2.x. 일별 62일·월별 25개월을 기본 보관해 별도 저장소 없이 분석합니다.
#         NIC 를 지난 바이트를 모두 세므로 OCI 내부 무료 트래픽도 포함돼 실제 과금량보다 크게 잡힙니다.
# 설정:   /etc/oci-free-traffic-alert.conf (환경변수 OCI_TRAFFIC_CONF 로 경로 변경 가능)
#
set -euo pipefail

CMD="${1:-}"
[[ "$CMD" =~ ^(check|report|status)$ ]] || { echo "사용법: $(basename "$0") check|report|status" >&2; exit 2; }

CONF="${OCI_TRAFFIC_CONF:-/etc/oci-free-traffic-alert.conf}"
if [[ -f "$CONF" ]]; then set -a; . "$CONF"; set +a; fi

IFACE="${IFACE:-$(ip route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}' || true)}"
LIMIT_GB="${LIMIT_GB:-10000}"           # OCI 무료 송신 월 10TB (1TB=1000GB 로 잡아 조금 일찍 경고)
ALERT_PCTS="${ALERT_PCTS:-50 80 95}"    # 이번 달 송신량이 이 비율(%)을 처음 넘을 때마다 알림
SPIKE_X="${SPIKE_X:-3}"                 # 오늘 송신이 최근 7일 평균의 이 배수 이상이면 급증 알림 (0 이면 끔)
SPIKE_MIN_GB="${SPIKE_MIN_GB:-10}"      # 단, 오늘 송신이 이 값(GB) 미만이면 급증으로 보지 않음
STATE_DIR="${STATE_DIR:-/var/lib/oci-free-traffic-alert}"
HOST_LABEL="${HOST_LABEL:-$(hostname)}"

die() { echo "❌ $*" >&2; exit 1; }

[[ -n "$IFACE" ]] || die "네트워크 인터페이스를 찾지 못했습니다. $CONF 에 IFACE 를 지정하세요."

# ── 날짜 (OCI_TRAFFIC_TODAY 는 테스트용 기준일) ──────────────────────────
TODAY=$(date -d "${OCI_TRAFFIC_TODAY:-today}" +%F)
DAY=$((10#${TODAY:8:2}))
DIM=$((10#$(date -d "${TODAY:0:7}-01 +1 month -1 day" +%d)))   # 이번 달 일수

# ── 사용량 읽기: 이번 달·오늘·어제·최근 7일(오늘 제외)을 날짜로 골라냄 ─────────
# 마지막 항목([-1])을 쓰면 새 달 첫 기록 전에는 지난달 값을 읽게 되므로 날짜로 매칭한다.
JSON=$(vnstat -i "$IFACE" --json) \
  || die "vnstat 조회 실패: '$IFACE' 가 등록돼 있는지 확인하세요 (sudo vnstat --add -i $IFACE)"
USAGE=$(jq -er --arg today "$TODAY" --arg yday "$(date -d "$TODAY -1 day" +%F)" \
             --arg from7 "$(date -d "$TODAY -7 days" +%F)" '
  def pad: tostring | if length < 2 then "0" + . else . end;
  def ym: "\(.year)-\(.month | pad)";
  if (.jsonversion | tostring) != "2" then error("vnstat 2.x 가 필요합니다") else . end
  | .interfaces[0].traffic as $t
  | ([$t.month[]? | select((.date | ym) == $today[0:7])] | first // {}) as $mon
  | [$t.day[]? | {d: (.date | "\(ym)-\(.day | pad)"), tx, rx}] as $days
  | ([$days[] | select(.d == $today)] | first // {}) as $td
  | [$days[] | select(.d >= $from7 and .d < $today) | .tx] as $week
  | [$mon.tx // 0, $mon.rx // 0, $td.tx // 0, $td.rx // 0,
     ([$days[] | select(.d == $yday) | .tx] | first // -1),
     (if ($week | length) > 0 then ($week | add) / ($week | length) else -1 end)]
  | map(tostring) | join(" ")' <<<"$JSON") || die "vnstat JSON 해석 실패"
read -r MONTH_TX MONTH_RX DAY_TX DAY_RX YDAY_TX AVG7_TX <<<"$USAGE"   # 없는 값은 -1

# awk 계산·서식. 사용량 변수를 모두 넘겨 두고 $1 의 문장을 실행한다.
#   pct   이번 달 사용률(%)
#   proj  월말 예상 송신 = 이번 달 누적 + 7일 평균 × 남은 일수 (이력이 없으면 일평균 × 이번 달 일수)
#   ratio 오늘 송신 ÷ 7일 평균
calc() {
  awk -v mtx="$MONTH_TX" -v mrx="$MONTH_RX" -v dtx="$DAY_TX" -v drx="$DAY_RX" -v ytx="$YDAY_TX" -v avg="$AVG7_TX" \
      -v lim="$LIMIT_GB" -v day="$DAY" -v dim="$DIM" -v sx="$SPIKE_X" -v smin="$SPIKE_MIN_GB" '
    function size(b) { return (b < 1e9) ? sprintf("%.1f MB", b / 1e6) : ((b < 1e12) ? sprintf("%.2f GB", b / 1e9) : sprintf("%.2f TB", b / 1e12)) }
    BEGIN {
      mtx += 0; mrx += 0; dtx += 0; drx += 0; ytx += 0; avg += 0; lim += 0; sx += 0; smin += 0
      L = lim * 1e9; pct = mtx / L * 100
      proj = (avg >= 0) ? mtx + avg * (dim - day) : mtx / day * dim
      ratio = (avg > 0) ? dtx / avg : 0
      '"$1"'
    }'
}

PCT=$(calc 'printf "%.2f", pct')
RATIO=$(calc 'printf "%.1f", ratio')
SPIKE=$(calc 'print ((sx > 0 && ratio >= sx && dtx >= smin * 1e9) ? 1 : 0)')
PROJ_OVER=$(calc 'print ((proj >= L) ? 1 : 0)')

# 지금 넘어선 임계치 중 가장 큰 값 (없으면 0)
LEVEL=0
for p in $ALERT_PCTS; do
  if awk -v a="$PCT" -v p="$p" 'BEGIN { exit !(a >= p) }' && (( p > LEVEL )); then LEVEL=$p; fi
done

# 알림용 요약 3줄
brief() {
  calc 'printf "• 이번 달 송신: %s (무료 한도의 %.2f%%)\n• 오늘 송신: %s\n• 월말 예상 송신: %s (%.2f%%)\n",
        size(mtx), pct, size(dtx), size(proj), proj / L * 100'
}

report_text() {
  local -a st=()
  (( LEVEL > 0 )) && st+=("⚠️ 무료 한도의 ${LEVEL}% 이상 사용")
  (( PROJ_OVER )) && st+=("🚨 이 추세면 월말에 무료 한도를 넘습니다")
  (( SPIKE )) && st+=("⚡ 오늘 송신이 최근 7일 평균의 ${RATIO}배")
  (( ${#st[@]} )) || st=("✅ 상태: 정상")

  echo "📊 OCI 트래픽 일일 리포트 [$HOST_LABEL]"
  echo "$TODAY $(date +%H:%M) 기준"
  echo
  calc '
    left = L - mtx; if (left < 0) left = 0
    printf "📡 오늘의 네트워크\n• 송신 TX: %s\n• 수신 RX: %s\n\n", size(dtx), size(drx)
    printf "🗓 이번 달 사용량\n• 송신 TX: %s\n• 수신 RX: %s (무료)\n• 무료 한도 사용률: %.2f%%\n• 남은 송신 한도: 약 %s\n\n",
           size(mtx), size(mrx), pct, size(left)
    printf "📈 트래픽 분석\n• 월말 예상 송신: %s (%.2f%%)\n", size(proj), proj / L * 100
    if (avg >= 0) printf "• 최근 7일 평균: %s/일\n", size(avg); else print "• 최근 7일 평균: 데이터 수집 중"
    if (ytx < 0) print "• 전일 대비: 데이터 수집 중"
    else if (ytx == 0) print "• 전일 대비: - (어제 0)"
    else printf "• 전일 대비: %+.0f%% (어제 %s)\n", (dtx - ytx) / ytx * 100, size(ytx)'
  echo
  printf '%s\n' "${st[@]}"
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
    echo "(인터페이스 $IFACE · 설정 $CONF)"
    report_text
    ;;
  report)
    notify "$(report_text)" || die "알림 전송 실패"
    echo "[$(date '+%F %T')] report sent (${PCT}%)"
    ;;
  check)
    mkdir -p "$STATE_DIR"
    month=${TODAY:0:7} prev_month="" prev_level=0
    if [[ -f "$STATE_DIR/state" ]]; then read -r prev_month prev_level < "$STATE_DIR/state" || true; fi
    [[ "$prev_month" == "$month" ]] || prev_level=0   # 달이 바뀌면 처음부터 다시 알림
    if (( LEVEL > prev_level )); then
      notify "🚨 OCI 송신 트래픽 경고 [$HOST_LABEL]
이번 달 송신량이 무료 한도의 ${LEVEL}%를 넘었습니다.
$(brief)
PAYG 계정은 무료 한도를 넘는 송신량부터 과금됩니다." || die "알림 전송 실패 — 다음 실행 때 다시 시도합니다"
      echo "$month $LEVEL" > "$STATE_DIR/state"
      echo "[$(date '+%F %T')] 임계치 알림 (${LEVEL}%, 현재 ${PCT}%)"
    fi
    # 급증 알림은 하루 1번
    if (( SPIKE )) && [[ "$(cat "$STATE_DIR/spike" 2>/dev/null || true)" != "$TODAY" ]]; then
      notify "⚡ OCI 송신 트래픽 급증 [$HOST_LABEL]
오늘 송신이 최근 7일 평균의 ${RATIO}배입니다.
$(brief)
어떤 프로세스가 보내는지 확인해 보세요 (예: sudo nethogs, sudo iftop)." || die "알림 전송 실패 — 다음 실행 때 다시 시도합니다"
      echo "$TODAY" > "$STATE_DIR/spike"
      echo "[$(date '+%F %T')] 급증 알림 (${RATIO}배)"
    fi
    ;;
esac
