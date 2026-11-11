# oci-free-traffic-alert

[![README: 한국어](https://img.shields.io/badge/README-%ED%95%9C%EA%B5%AD%EC%96%B4-blue)](README.md)

Watches this month's **outbound (egress) traffic** on an Oracle Cloud (OCI) free-tier server against the 10 TB/month free allowance, and alerts you via Telegram or a webhook (Slack, Discord, Google Chat). The daily report adds a month-end projection, a 7-day average and a day-over-day change, and you get an immediate alert when usage nears the limit or suddenly spikes. Two shell scripts and cron, nothing else.

> Alert messages are written in Korean.

## Why

- On a Pay As You Go (PAYG) account, egress beyond the free allowance is billed.
- OCI quota policies cannot cap egress, and Budget alerts only fire **after** charges appear.
- A1 instances get 1 Gbps per OCPU, so a 2-OCPU server sending at full speed could in theory pass 10 TB in about half a day. That is why thresholds and spikes are checked **every 10 minutes**, not only in the daily report.

## Requirements

- An OCI instance (Ubuntu or Oracle Linux) with `sudo`
- At least one alert channel: a Telegram bot token + chat ID, or a webhook URL that accepts `{"text": "..."}` JSON

## Install

```bash
git clone https://github.com/100rootrain/oci-free-traffic-alert.git
cd oci-free-traffic-alert
sudo bash install.sh
```

The installer adds `vnstat`, `jq` and `curl` (enabling EPEL on Oracle Linux), installs the script to `/usr/local/bin/oci-free-traffic-alert` and the config to `/etc/oci-free-traffic-alert.conf`, registers the default network interface with vnstat, and adds `/etc/cron.d/oci-free-traffic-alert`. Re-running it is safe; an existing config is kept.

## Configure

Edit `/etc/oci-free-traffic-alert.conf` (see [config.example](config.example)):

```bash
TELEGRAM_BOT_TOKEN=123456:ABC...   # from @BotFather
TELEGRAM_CHAT_ID=123456789         # see https://api.telegram.org/bot<token>/getUpdates
WEBHOOK_URL=https://hooks.slack.com/services/...   # Discord: append /slack to the webhook URL
```

Optional: `HOST_LABEL` (default `hostname`), `IFACE` (default: interface of the default route), `LIMIT_GB` (default `10000`), `ALERT_PCTS` (default `"50 80 95"`), `SPIKE_X` (default `3`, `0` disables spike alerts), `SPIKE_MIN_GB` (default `10`).

## Test

```bash
sudo oci-free-traffic-alert status   # print usage, send nothing
sudo oci-free-traffic-alert report   # send one report now
```

vnstat needs about 5 minutes to collect its first data after install.

## How it works

| When | Command | What it does |
|---|---|---|
| Every 10 min | `check` | (1) Alerts when this month's egress **newly** crosses 50% / 80% / 95% (each level once per month). (2) Spike alert when today's egress is at least 3× the 7-day average and at least 10 GB (once per day) |
| Daily 23:55 | `report` | Sends today's and this month's usage plus the analysis |

- **Month-end projection** = month-to-date + 7-day average × remaining days (falls back to the daily average so far when there is no history). If it exceeds the allowance, the report says so.
- **7-day average** covers the 7 days before today.
- History comes from vnstat itself (by default 62 days of daily and 25 months of monthly data); no database is needed.

- Cron uses the server time zone (UTC on default OCI images).
- Logs: `journalctl -t oci-free-traffic-alert`.

## Caveats

- **Counts more than you are billed for.** vnstat counts every byte through the NIC, including free OCI-internal traffic, and 1 TB is treated as 1000 GB. Both make alerts fire early, not late.
- **Counts from install time.** Check earlier usage this month in the OCI console's Cost analysis.
- **The month follows the server time zone.**

## Also set up in the OCI console

1. **Budget alert** — a $1 budget with an alert rule emails you as soon as any charge appears.
2. **Quota policy** — block resources beyond the free tier. The A1 free allowance is 2 OCPU / 12 GB since June 2026. Put all statements in **one** policy (across policies the most restrictive wins, so a separate `zero` would block A1 too). See the Korean README for the full statement list and how to check which `-regional-count` names exist in your region.

## Uninstall

```bash
sudo rm /etc/cron.d/oci-free-traffic-alert /usr/local/bin/oci-free-traffic-alert /etc/oci-free-traffic-alert.conf
sudo rm -r /var/lib/oci-free-traffic-alert
```

## Development

```bash
bash tests/test.sh   # fakes vnstat and curl to verify alerts and analysis (needs bash, jq, awk, GNU date)
```

## License

[MIT](LICENSE)
