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
read -r MONTH_TX MONTH_RX DAY_TX DAY_RX YDAY_TX AVG7_TX <<<"$USAGE"   # 이력이 없으면 YDAY_TX·AVG7_TX = -1

# ── 계산: 수치와 문구를 awk 한 번에 구해 리포트·알림이 같은 값을 쓴다 ───────────
#   월말 예상 = 이번 달 누적 + 7일 평균 × 남은 일수 (이력이 없으면 일평균 × 이번 달 일수)
#   급증     = 7일 이력이 있고(평균 0 포함), 오늘 송신 ≥ 평균 × SPIKE_X 이며 SPIKE_MIN_GB 이상
#   단계     = 이번 달 사용률이 넘어선 ALERT_PCTS 중 가장 큰 값 (없으면 0)
CALC=$(
  awk -v mtx="$MONTH_TX" -v mrx="$MONTH_RX" -v dtx="$DAY_TX" -v drx="$DAY_RX" -v ytx="$YDAY_TX" -v avg="$AVG7_TX" \
      -v lim="$LIMIT_GB" -v pcts="$ALERT_PCTS" -v day="$DAY" -v dim="$DIM" -v sx="$SPIKE_X" -v smin="$SPIKE_MIN_GB" '
    function size(b) { return (b < 1e9) ? sprintf("%.1f MB", b / 1e6) : ((b < 1e12) ? sprintf("%.2f GB", b / 1e9) : sprintf("%.2f TB", b / 1e12)) }
    BEGIN {
      mtx += 0; mrx += 0; dtx += 0; drx += 0; ytx += 0; avg += 0; lim += 0; sx += 0; smin += 0
      if (lim <= 0) { print "LIMIT_GB 는 0보다 커야 합니다" > "/dev/stderr"; exit 1 }
      L = lim * 1e9; pct = mtx / L * 100; left = (L > mtx) ? L - mtx : 0
      proj = (avg >= 0) ? mtx + avg * (dim - day) : mtx / day * dim
      level = 0; n = split(pcts, P, " ")
      for (i = 1; i <= n; i++) if (pct >= P[i] + 0 && P[i] + 0 > level) level = P[i] + 0
      spike = (sx > 0 && avg >= 0 && dtx >= avg * sx && dtx >= smin * 1e9)
      if (!spike) smsg = "-"
      else if (avg > 0) smsg = sprintf("오늘 송신이 최근 7일 평균의 %.1f배입니다", dtx / avg)
      else smsg = sprintf("최근 7일 송신이 없었는데 오늘 %s를 보냈습니다", size(dtx))
      savg = (avg >= 0) ? size(avg) "/일" : "데이터 수집 중"
      if (ytx < 0) sdod = "데이터 수집 중"
      else if (ytx == 0) sdod = "- (어제 0)"
      else sdod = sprintf("%+.0f%% (어제 %s)", (dtx - ytx) / ytx * 100, size(ytx))
      printf "%.2f\t%.2f\t%d\t%d\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", pct, proj / L * 100, (proj > L), level, spike,
             smsg, size(mtx), size(mrx), size(dtx), size(drx), size(left), size(proj), savg, sdod
    }') || die "사용량 계산 실패 — 설정값(LIMIT_GB·ALERT_PCTS·SPIKE_X·SPIKE_MIN_GB)을 확인하세요"
IFS=$'\t' read -r PCT PROJ_PCT PROJ_OVER LEVEL SPIKE SPIKE_MSG S_MTX S_MRX S_DTX S_DRX S_LEFT S_PROJ S_AVG S_DOD <<<"$CALC"

# 알림용 요약 3줄
brief() {
  printf '%s\n' "• 이번 달 송신: $S_MTX (무료 한도의 ${PCT}%)" "• 오늘 송신: $S_DTX" "• 월말 예상 송신: $S_PROJ (${PROJ_PCT}%)"
}

report_text() {
  local -a st=()
  (( LEVEL > 0 )) && st+=("⚠️ 무료 한도의 ${LEVEL}% 이상 사용")
  (( PROJ_OVER )) && st+=("🚨 이 추세면 월말에 무료 한도를 넘습니다")
  (( SPIKE )) && st+=("⚡ $SPIKE_MSG")
  (( ${#st[@]} )) || st=("✅ 상태: 정상")
  cat <<EOF
📊 OCI 트래픽 일일 리포트 [$HOST_LABEL]
$TODAY $(date +%H:%M) 기준

📡 오늘의 네트워크
• 송신 TX: $S_DTX
• 수신 RX: $S_DRX

🗓 이번 달 사용량
• 송신 TX: $S_MTX
• 수신 RX: $S_MRX (무료)
• 무료 한도 사용률: ${PCT}%
• 남은 송신 한도: 약 $S_LEFT

📈 트래픽 분석
• 월말 예상 송신: $S_PROJ (${PROJ_PCT}%)
• 최근 7일 평균: $S_AVG
• 전일 대비: $S_DOD

EOF
  printf '%s\n' "${st[@]}"
}

# ── 전송 ──────────────────────────────────────────────────────────────
send_telegram() {
  curl -fsS --max-time 15 -o /dev/null "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=$1"
}
send_webhook() {
  jq -n --arg t "$1" '{text: $t}' \
    | curl -fsS --max-time 15 -o /dev/null -H 'Content-Type: application/json' -d @- "$WEBHOOK_URL"
}
CHANNELS=()
if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then CHANNELS+=(telegram); fi
if [[ -n "${WEBHOOK_URL:-}" ]]; then CHANNELS+=(webhook); fi

# newer <새 키> <기록된 키>: 키는 "YYYY-MM 단계"(임계치) 또는 "YYYY-MM-DD"(급증).
#   앞부분(월·날짜)이 더 늦거나, 같으면 단계가 숫자로 더 클 때 참.
newer() {
  local nk nl ok ol
  read -r nk nl <<<"$1"; read -r ok ol <<<"$2"
  [[ "$nk" > "$ok" ]] || { [[ "$nk" == "$ok" ]] && (( 10#${nl:-0} > 10#${ol:-0} )); }
}

# deliver <상태이름|""> <키> <본문>
#   상태이름이 있으면 채널마다 기록된 키보다 새 키가 newer 일 때만 보내고, 성공한 채널에만 키를 기록한다.
#   → 한 채널이 실패해도 성공한 채널엔 다시 가지 않고, 실패한 채널만 다음 실행 때 재시도한다.
#   새 키는 임시 파일(<파일>.tmp)에 먼저 다 써 두고, 쓰기에 실패하면 보내지 않는다
#   (기록 못 한 채 보내면 매번 다시 보내게 됨). 보낸 뒤에만 기존 파일과 원자적으로 교체하고,
#   전송이 실패하면 임시 파일만 지운다 → 실패해도 기존 채널 기록과 첫 버전 state 승계가 그대로 남는다.
#   첫 버전은 임계치 상태를 채널 구분 없이 STATE_DIR/state 에 같은 형식으로 남겼으므로,
#   채널 파일이 아직 없으면 그 값을 이어받는다.
deliver() {
  local name=$1 key=$2 text=$3 ch f old failed=0
  (( ${#CHANNELS[@]} )) || die "알림 채널이 없습니다: $CONF 에 TELEGRAM_BOT_TOKEN·TELEGRAM_CHAT_ID 또는 WEBHOOK_URL 을 입력하세요"
  for ch in "${CHANNELS[@]}"; do
    if [[ -n "$name" ]]; then
      f="$STATE_DIR/$name.$ch" old=""
      if [[ -f "$f" ]]; then old=$(cat "$f"); elif [[ "$name" == level && -f "$STATE_DIR/state" ]]; then old=$(cat "$STATE_DIR/state"); fi
      newer "$key" "$old" || continue
      # 기존 경로가 디렉터리 등 파일이 아니면 보낸 뒤 교체(mv)가 실패해 매번 다시 보내게 되므로 미리 막는다.
      if [[ -e "$f" && ! -f "$f" ]] || ! echo "$key" 2>/dev/null > "$f.tmp"; then
        rm -f "$f.tmp" 2>/dev/null; echo "❌ 상태 파일에 쓸 수 없어 보내지 않습니다: $f" >&2; failed=1; continue
      fi
    fi
    if "send_$ch" "$text"; then
      if [[ -n "$name" ]] && ! mv -fT "$f.tmp" "$f" 2>/dev/null; then
        rm -f "$f.tmp"; echo "❌ $name → $ch 는 보냈지만 상태 기록 실패: $f (다음 실행 때 다시 보낼 수 있음)" >&2; failed=1; continue
      fi
      echo "[$(date '+%F %T')] ${name:-report} → $ch 전송"
    else
      if [[ -n "$name" ]]; then rm -f "$f.tmp"; fi
      echo "❌ ${name:-report} → $ch 전송 실패 (check 는 다음 실행 때 다시 시도)" >&2; failed=1
    fi
  done
  return "$failed"
}

case "$CMD" in
  status)
    echo "(인터페이스 $IFACE · 설정 $CONF)"
    report_text
    ;;
  report)
    deliver "" "" "$(report_text)"
    ;;
  check)
    mkdir -p "$STATE_DIR"
    # 상태 확인 → 전송 → 기록을 한 번에 하나씩 (수동 실행과 cron 이 겹쳐도 중복 전송 방지).
    # flock 은 Linux(util-linux) 기본 명령. 없는 개발 환경에서만 잠금 없이 진행.
    exec 9>"$STATE_DIR/lock"
    if command -v flock >/dev/null; then flock -w 60 9 || die "다른 check 실행이 끝나지 않았습니다"; fi
    failed=0
    if (( LEVEL > 0 )); then
      deliver level "${TODAY:0:7} $LEVEL" "🚨 OCI 송신 트래픽 경고 [$HOST_LABEL]
이번 달 송신량이 무료 한도의 ${LEVEL}%를 넘었습니다.
$(brief)
PAYG 계정은 무료 한도를 넘는 송신량부터 과금됩니다." || failed=1
    fi
    if (( SPIKE )); then   # 하루 한 번
      deliver spike "$TODAY" "⚡ OCI 송신 트래픽 급증 [$HOST_LABEL]
${SPIKE_MSG}.
$(brief)
어떤 프로세스가 보내는지 확인해 보세요 (예: sudo nethogs, sudo iftop)." || failed=1
    fi
    exit "$failed"
    ;;
esac
