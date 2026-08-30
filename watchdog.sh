#!/usr/bin/env bash
# Homelab watchdog: classify homelab health from report.json + code.txt,
# send Telegram alert ONLY on state change, keep state.json committed.
set -u

CODE=$(cat code.txt 2>/dev/null || echo 000)
BASE=$(cat base.txt 2>/dev/null || echo 000)
PREV=$(cat state.json 2>/dev/null || echo '{"state":"UNKNOWN"}')

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

send() {
  local text="$1"
  curl -sS --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    -d "text=${text}" \
    -d "parse_mode=Markdown" >/dev/null 2>&1 || echo "TELEGRAM_SEND_FAILED"
}

# Parse report.json with python3 (json stdlib — works everywhere, no jq dep)
read -r OK TOTAL DOWN CRIT ERR <<EOF
$(python3 - <<'PY'
import json, sys
try:
    d = json.load(open("report.json"))
except Exception:
    print("false 0 - - ''")
    sys.exit(0)
ok = "true" if d.get("ok") else "false"
total = d.get("total", 0)
down = ",".join(d.get("down", []))
crit = ",".join(d.get("critical_down", []))
err = d.get("error", "")
print(f"{ok} {total} {down} {crit} {err}")
PY
)
EOF

NEW_STATE="UNKNOWN"
DETAIL=""

if [ "$CODE" = "000" ] && [ "$BASE" = "000" ]; then
  NEW_STATE="POWER_OUT"
  DETAIL="Homelab and tunnel unreachable — likely power cut or network down"
elif [ "$CODE" = "000" ] && [ "$BASE" != "000" ]; then
  NEW_STATE="HEALTHD_DOWN"
  DETAIL="health.mymaker.in unreachable but mymaker.in is up — healthd container or tunnel route broken"
elif [ "$OK" = "true" ]; then
  NEW_STATE="UP"
  DETAIL="All ${TOTAL} containers up"
elif [ "$ERR" = "docker_unreachable" ]; then
  NEW_STATE="DOCKER_UNREACHABLE"
  DETAIL="healthd cannot reach docker daemon"
else
  NEW_STATE="DOWN"
  DETAIL="Down: ${DOWN}"
  [ -n "$CRIT" ] && DETAIL="⚠️ CRITICAL: ${CRIT} | ${DETAIL}"
fi

OLD_STATE=$(python3 -c 'import json;print(json.loads("""'"$PREV"'""").get("state","UNKNOWN"))' 2>/dev/null || echo "UNKNOWN")

if [ "$OLD_STATE" != "$NEW_STATE" ]; then
  case "$NEW_STATE" in
    UP)           MSG="✅ *HOMELAB RECOVERED*\n${DETAIL}\n⏱ $(now)" ;;
    POWER_OUT)    MSG="🚨 *HOMELAB UNREACHABLE*\n${DETAIL}\n⏱ $(now)" ;;
    HEALTHD_DOWN) MSG="⚠️ *HEALTHD DOWN*\n${DETAIL}\n⏱ $(now)" ;;
    DOCKER_UNREACHABLE) MSG="⚠️ *DOCKER DAEMON UNREACHABLE*\n${DETAIL}\n⏱ $(now)" ;;
    DOWN)         MSG="🚨 *CONTAINER(S) DOWN*\n${DETAIL}\n⏱ $(now)" ;;
    *)            MSG="❓ *UNKNOWN STATE* ${NEW_STATE}\n${DETAIL}\n⏱ $(now)" ;;
  esac
  send "$MSG" || true
fi

python3 -c 'import json,sys; json.dump({"state":sys.argv[1],"detail":sys.argv[2],"at":sys.argv[3]}, open("state.json","w"))' "$NEW_STATE" "$DETAIL" "$(now)"

# Commit every run → defeats GitHub's 60-day cron-disabling rule
git config user.name "homelab-watchdog" >/dev/null 2>&1
git config user.email "watchdog@users.noreply.github.com" >/dev/null 2>&1
git add state.json >/dev/null 2>&1
git commit -m "watchdog state $(now)" >/dev/null 2>&1
git push >/dev/null 2>&1 || echo "PUSH_FAILED (non-fatal)"

echo "state=$NEW_STATE (was $OLD_STATE) detail=$DETAIL"