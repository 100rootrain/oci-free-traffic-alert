#!/usr/bin/env bash
#
# install.sh — oci-free-traffic-alert 설치 (Ubuntu / Oracle Linux)
#   1) vnstat·jq·curl 설치   2) 실행 파일·설정 파일 배치
#   3) vnstat 에 인터페이스 등록   4) cron 등록   5) 설정돼 있으면 테스트 리포트 전송
# 다시 실행해도 안전합니다(기존 설정 파일은 덮어쓰지 않음).
#
set -euo pipefail
[[ $EUID -eq 0 ]] || exec sudo bash "$0" "$@"
cd "$(dirname "$0")"

NAME=oci-free-traffic-alert
CONF=/etc/$NAME.conf

# 1. 패키지
if command -v apt-get >/dev/null; then
  apt-get update -qq && apt-get install -y -qq vnstat jq curl
elif command -v dnf >/dev/null; then
  dnf install -y -q "oracle-epel-release-el$(rpm -E %rhel)" || true   # Oracle Linux 는 vnstat 이 EPEL 에 있음
  dnf install -y -q vnstat jq curl
else
  echo "❌ apt-get/dnf 를 찾지 못했습니다. vnstat, jq, curl 을 직접 설치한 뒤 다시 실행하세요." >&2
  exit 1
fi

# 2. 실행 파일·설정 파일
install -m 755 "$NAME.sh" "/usr/local/bin/$NAME"
[[ -f "$CONF" ]] || install -m 600 config.example "$CONF"
mkdir -p "/var/lib/$NAME"

# 3. vnstat 에 인터페이스 등록 (설정의 IFACE, 없으면 기본 라우트 인터페이스)
IFACE=$(. "$CONF"; echo "${IFACE:-}")
IFACE="${IFACE:-$(ip route show default | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')}"
systemctl enable --now vnstat
vnstat --add -i "$IFACE" >/dev/null 2>&1 || true   # 이미 등록돼 있으면 무시
systemctl restart vnstat

# 4. cron — 시간은 서버 시간대 기준 (OCI 기본 이미지는 UTC: 23:55 UTC = 한국 08:55)
cat > "/etc/cron.d/$NAME" <<EOF
# $NAME: 10분마다 임계치 확인, 매일 23:55 요약. 로그: journalctl -t $NAME
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
*/10 * * * * root $NAME check 2>&1 | logger -t $NAME
55 23 * * * root $NAME report 2>&1 | logger -t $NAME
EOF

# 5. 확인
echo "✅ 설치 완료 (인터페이스: $IFACE). vnstat 이 첫 데이터를 모으는 데 5분쯤 걸립니다."
if grep -qE '^(TELEGRAM_BOT_TOKEN|WEBHOOK_URL)=.+' "$CONF"; then
  "$NAME" report && echo "📨 테스트 리포트를 보냈습니다."
else
  echo "👉 $CONF 에 알림 채널을 입력한 뒤 'sudo $NAME report' 로 테스트하세요."
fi
