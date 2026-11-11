# oci-free-traffic-alert

[![README: English](https://img.shields.io/badge/README-English-blue)](README.en.md)

Oracle Cloud(OCI) 무료 서버의 **이번 달 송신(egress) 트래픽**을 무료 한도(월 10TB)와 비교해 텔레그램이나 Slack·Discord 같은 웹훅으로 알려 줍니다. 매일 리포트에 월말 예상·7일 평균·전일 대비를 붙이고, 한도에 가까워지거나 송신이 갑자기 늘면 바로 경고합니다. 스크립트 두 개(설치용, 실행용)와 cron만 씁니다.

```
📊 OCI 트래픽 일일 리포트 [my-oci-server]
2026-10-31 23:55 기준

📡 오늘의 네트워크
• 송신 TX: 872.2 MB
• 수신 RX: 11.66 GB

🗓 이번 달 사용량
• 송신 TX: 54.80 GB
• 수신 RX: 871.68 GB (무료)
• 무료 한도 사용률: 0.55%
• 남은 송신 한도: 약 9.95 TB

📈 트래픽 분석
• 월말 예상 송신: 54.80 GB (0.55%)
• 최근 7일 평균: 1.97 GB/일
• 전일 대비: -56% (어제 2.00 GB)

✅ 상태: 정상
```

## 왜 필요한가요

- Pay As You Go(PAYG)로 전환한 계정은 무료 한도를 넘는 송신량부터 요금이 붙습니다.
- OCI 쿼터 정책으로는 송신량을 막을 수 없습니다. 예산(Budgets) 알림은 요금이 생긴 **뒤에** 옵니다.
- A1 인스턴스는 OCPU당 1Gbps라서, 2 OCPU 서버가 최대 속도로 계속 보내면 이론상 반나절 만에 10TB를 넘길 수 있습니다. 그래서 하루 한 번 리포트와 별개로 **10분마다** 임계치와 급증 여부를 확인합니다.

## 준비물

- OCI 인스턴스(Ubuntu 또는 Oracle Linux)와 `sudo` 권한
- 알림 받을 곳 하나 이상
  - 텔레그램 봇 토큰과 채팅 ID, 또는
  - `{"text": "..."}` JSON을 받는 웹훅 주소 (Slack Incoming Webhook, Google Chat, Discord)

## 1. 설치하기

서버에 SSH로 접속해 아래를 실행합니다.

```bash
git clone https://github.com/100rootrain/oci-free-traffic-alert.git
cd oci-free-traffic-alert
sudo bash install.sh
```

설치 스크립트가 하는 일:

1. `vnstat`, `jq`, `curl` 설치 (Oracle Linux는 EPEL 저장소도 켭니다)
2. 실행 파일을 `/usr/local/bin/oci-free-traffic-alert`에, 설정 파일을 `/etc/oci-free-traffic-alert.conf`에 둡니다
3. 기본 네트워크 인터페이스를 vnstat에 등록합니다
4. cron을 등록합니다 (`/etc/cron.d/oci-free-traffic-alert`)

다시 실행해도 안전합니다. 이미 있는 설정 파일은 덮어쓰지 않습니다.

## 2. 알림 채널 입력하기

```bash
sudo nano /etc/oci-free-traffic-alert.conf
```

**텔레그램을 쓸 때**

1. 텔레그램에서 `@BotFather`에게 `/newbot`을 보내 봇을 만들고 토큰을 받습니다.
2. 만든 봇에게 아무 메시지나 보냅니다.
3. 브라우저에서 `https://api.telegram.org/bot<토큰>/getUpdates`를 열고 `"chat":{"id": ...}` 숫자를 찾습니다.
4. 설정 파일에 입력합니다.

```bash
TELEGRAM_BOT_TOKEN=123456:ABC...
TELEGRAM_CHAT_ID=123456789
```

**웹훅을 쓸 때**

```bash
WEBHOOK_URL=https://hooks.slack.com/services/...
```

Discord 웹훅은 주소 끝에 `/slack`을 붙여서 입력합니다. 둘 다 입력하면 둘 다 보냅니다.

## 3. 테스트하기

```bash
sudo oci-free-traffic-alert status   # 전송 없이 사용량만 출력
sudo oci-free-traffic-alert report   # 지금 리포트 1건 전송
```

vnstat은 설치 직후 첫 데이터를 모으는 데 5분쯤 걸립니다. 처음엔 0으로 보여도 정상입니다.

## 동작 방식

| 언제 | 명령 | 하는 일 |
|---|---|---|
| 10분마다 | `check` | ① 이번 달 송신량이 50%·80%·95%를 **새로** 넘으면 알림 (같은 단계는 한 달에 한 번)<br>② 오늘 송신이 최근 7일 평균의 3배 이상이고 10GB 이상이면 급증 알림 (하루 한 번) |
| 매일 23:55 | `report` | 오늘·이번 달 사용량과 트래픽 분석 리포트 전송 |

리포트의 분석 항목은 이렇게 계산합니다.

- **월말 예상 송신** = 이번 달 누적 + 최근 7일 평균 × 남은 일수. 이력이 없으면 지금까지의 일평균으로 계산합니다. 예상이 무료 한도를 넘으면 `🚨 이 추세면 월말에 무료 한도를 넘습니다`가 붙습니다.
- **최근 7일 평균**은 오늘을 뺀 지난 7일의 하루 평균입니다.
- 이력은 vnstat이 보관합니다(기본: 일별 62일, 월별 25개월). 따로 DB를 두지 않습니다.
- 채널을 둘 다 쓸 때 한쪽 전송이 실패하면, 성공한 쪽에는 다시 보내지 않고 실패한 쪽만 다음 `check` 때 다시 보냅니다.

- cron 시간은 서버 시간대를 따릅니다. OCI 기본 이미지는 UTC라서 23:55는 한국 시간 08:55입니다. 바꾸려면 `/etc/cron.d/oci-free-traffic-alert`를 고치세요.
- 로그는 `journalctl -t oci-free-traffic-alert`로 봅니다.

## 설정 항목

| 이름 | 기본값 | 설명 |
|---|---|---|
| `TELEGRAM_BOT_TOKEN`, `TELEGRAM_CHAT_ID` | (없음) | 텔레그램 알림 |
| `WEBHOOK_URL` | (없음) | 웹훅 알림 |
| `HOST_LABEL` | `hostname` | 알림에 표시할 서버 이름 |
| `IFACE` | 기본 라우트 인터페이스 | 감시할 네트워크 인터페이스 |
| `LIMIT_GB` | `10000` | 월 무료 송신 한도(GB) |
| `ALERT_PCTS` | `"50 80 95"` | 알림을 보낼 비율(%), 정수를 공백으로 구분 |
| `SPIKE_X` | `3` | 오늘 송신이 최근 7일 평균의 몇 배 이상이면 급증으로 볼지 (`0`이면 끔) |
| `SPIKE_MIN_GB` | `10` | 오늘 송신이 이 값(GB) 미만이면 급증으로 보지 않음 |

## 알아둘 점

- **실제 과금량보다 크게 잡힙니다.** vnstat은 네트워크 카드를 지난 바이트를 모두 세서, 과금되지 않는 OCI 내부 트래픽도 포함합니다. 1TB도 1000GB로 계산합니다. 둘 다 조금 일찍 경고하는 쪽입니다.
- **설치한 때부터 셉니다.** 이번 달 앞부분 사용량은 OCI 콘솔의 Cost analysis에서 확인하세요.
- **월 기준은 서버 시간대입니다.** 서버가 UTC면 매월 1일 00:00 UTC에 0부터 다시 셉니다.

## 함께 걸어 두면 좋은 설정 (OCI 콘솔)

1. **예산 알림** — Billing & Cost Management → Budgets에서 예산을 1달러로 잡고 알림 규칙을 겁니다. 어떤 이유로든 요금이 생기면 메일이 옵니다.
2. **쿼터 정책** — Governance & Administration → Quota policies에서 무료 한도까지만 자원을 만들 수 있게 막습니다. A1 무료 한도는 2026년 6월부터 2 OCPU / 12GB입니다.

   ```
   zero compute-core quotas in tenancy
   set compute-core quota standard-a1-core-count to 2 in tenancy
   set compute-core quota standard-a1-core-regional-count to 2 in tenancy
   zero compute-memory quotas in tenancy
   set compute-memory quota standard-a1-memory-count to 12 in tenancy
   set compute-memory quota standard-a1-memory-regional-count to 12 in tenancy
   set block-storage quota total-storage-gb to 200 in tenancy
   set block-storage quota backup-count to 5 in tenancy
   ```

   - 반드시 **하나의 정책**에 넣으세요. 정책이 여러 개면 가장 제한이 센 쪽이 이겨서 `zero`가 A1까지 막습니다.
   - `-regional-count` 이름은 리전마다 있을 수도, 없을 수도 있습니다. Cloud Shell에서 아래 명령으로 확인하고 나온 A1 항목을 모두 허용하세요.

     ```bash
     oci limits definition list --compartment-id "$OCI_TENANCY" --service-name compute --all \
       --query "data[?contains(name,'a1')].[name,\"scope-type\"]" --output table
     ```

   - 쿼터는 새로 만들거나 크기를 바꿀 때만 검사합니다. 이미 돌고 있는 인스턴스에는 영향이 없습니다.

## 삭제하기

```bash
sudo rm /etc/cron.d/oci-free-traffic-alert /usr/local/bin/oci-free-traffic-alert /etc/oci-free-traffic-alert.conf
sudo rm -r /var/lib/oci-free-traffic-alert
```

vnstat도 필요 없으면 `sudo apt remove vnstat`(Oracle Linux는 `sudo dnf remove vnstat`)으로 지웁니다.

## 개발

```bash
bash tests/test.sh   # vnstat·curl을 가짜로 바꿔 알림·분석 동작을 확인 (bash, jq, awk, GNU date 필요)
```

## 라이선스

[MIT](LICENSE)
