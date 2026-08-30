#!/usr/bin/env bash
# Homelab watchdog v3: classify homelab health from report.json + code.txt,
# send Telegram alert ONLY on state change, keep state.json committed.
set -u

CODE=$(cat code.txt 2>/dev/null || echo 000)
BASE=$(cat base.txt 2>/dev/null || echo 000)
PREV=$(cat state.json 2>/dev/null || echo '{"state":"UNKNOWN"}')

now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
NL=$'\n'   # real newline for Telegram

send() {
  local text="$1"
  curl -sS --max-time 15 -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -d "chat_id=${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${text}" \
    -d "parse_mode=HTML" >/dev/null 2>&1 || echo "TELEGRAM_SEND_FAILED"
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

# Build the full container status list (legend: 🟢 up, 🔴 down)
CLIST=$(python3 - <<'PY'
import json
try:
    d = json.load(open("report.json"))
    conts = d.get("containers", [])
except Exception:
    conts = []
lines = []
for c in sorted(conts, key=lambda x: x["name"]):
    mark = "🟢" if not c["down"] else "🔴"
    health = f" ({c['health']})" if c.get("health") else ""
    lines.append(f"{mark} {c['name']}{health}")
print("\n".join(lines) if lines else "— no data —")
PY
)

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
  NDOWN=$(echo "$DOWN" | tr ',' '\n' | grep -c . || true)
  DETAIL="⬇️ Down (${NDOWN}): ${DOWN}"
  [ -n "$CRIT" ] && DETAIL="${DETAIL}${NL}⚠️ CRITICAL: ${CRIT}"
fi

OLD_STATE=$(python3 -c 'import json;print(json.loads("""'"$PREV"'""").get("state","UNKNOWN"))' 2>/dev/null || echo "UNKNOWN")

if [ "$OLD_STATE" != "$NEW_STATE" ]; then
  case "$NEW_STATE" in
    UP)
      MSG="✅ <b>HOMELAB RECOVERED</b>${NL}${DETAIL}${NL}${NL}📋 <b>All containers (${TOTAL})</b>:${NL}${CLIST}${NL}⏱ $(now)"
      ;;
    POWER_OUT)
      MSG="🚨 <b>HOMELAB UNREACHABLE</b>${NL}${DETAIL}${NL}⏱ $(now)"
      ;;
    HEALTHD_DOWN)
      MSG="⚠️ <b>HEALTHD DOWN</b>${NL}${DETAIL}${NL}⏱ $(now)"
      ;;
    DOCKER_UNREACHABLE)
      MSG="⚠️ <b>DOCKER DAEMON UNREACHABLE</b>${NL}${DETAIL}${NL}⏱ $(now)"
      ;;
    DOWN)
      MSG="🚨 <b>CONTAINER(S) DOWN</b>${NL}${DETAIL}${NL}${NL}📋 <b>All containers (${TOTAL})</b>:${NL}${CLIST}${NL}⏱ $(now)"
      ;;
    *)
      MSG="❓ <b>UNKNOWN STATE</b> ${NEW_STATE}${NL}${DETAIL}${NL}⏱ $(now)"
      ;;
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