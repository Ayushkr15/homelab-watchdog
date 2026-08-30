# homelab-watchdog

Free, always-on uptime watchdog for the lazysenpai homelab.

- **Monitors:** every Docker container on the homelab (22 services) via a `healthd` endpoint exposed through the Cloudflare Tunnel at `https://health.mymaker.in/healthz`
- **Runs in:** GitHub Actions (free tier, public repo), every 5 minutes — stays alive even during a full home power cut
- **Alerts:** Telegram (dedicated bot), only on **state changes** (no spam)

## Architecture

```
GitHub Actions (cron */5) → health.mymaker.in (CF Tunnel) → healthd:8085 (docker.sock RO)
    → JSON {ok,total,up,down,critical_down} → state.json diff → Telegram alert
```

## Secrets (repo → Settings → Secrets and variables → Actions)

| Name | Value |
|---|---|
| `HEALTHD_TOKEN` | from `/opt/homelab/healthd/.env` on lazysenpai |
| `TELEGRAM_BOT_TOKEN` | from @BotFather |
| `TELEGRAM_CHAT_ID` | Ayush's Telegram user id (`650162025`) |

## Manual test

```bash
curl "https://health.mymaker.in/healthz?token=$HEALTHD_TOKEN"
# → {"ok": true, "total": 22, "up": 22, ...}
```

To force an alert: `docker stop searxng` on the homelab → within 5 min a 🚨 critical alert arrives → `docker start searxng` → ✅ recovery.

State is committed to this repo on every run (also defeats GitHub's 60-day scheduled-workflow inactivity rule).