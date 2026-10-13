#!/usr/bin/env bash
# 檢查 Steam public branch Build ID，有變化時推播 Discord，推播成功後才 commit state.json。
set -euo pipefail

APP_ID=4623570
API_URL="https://api.steamcmd.net/v1/info/${APP_ID}"
STATE_FILE=state.json
USERNAME="桌面破壞神更新監控"

: "${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL 未設定}"

tw_time() { TZ=Asia/Taipei date -d "@$1" '+%Y-%m-%d %H:%M:%S'; }

notify() {
  jq -n --arg u "$USERNAME" --arg c "$1" '{username: $u, content: $c}' |
    curl -fsS --retry 3 --max-time 20 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_URL" >/dev/null
}

commit_state() {
  local cur='{}'
  [[ -f "$STATE_FILE" ]] && cur=$(cat "$STATE_FILE")
  jq --arg b "$1" '.buildid = $b' <<<"$cur" > "$STATE_FILE"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$STATE_FILE"
  git commit -q -m "$2"
  git push -q
}

resp=$(curl -fsS --retry 3 --retry-all-errors --max-time 30 "$API_URL")
status=$(jq -r '.status // empty' <<<"$resp")
pub=".data[\"$APP_ID\"].depots.branches.public"
new=$(jq -r "$pub.buildid // empty" <<<"$resp")
updated=$(jq -r "$pub.timeupdated // empty" <<<"$resp")

if [[ "$status" != "success" || ! "$new" =~ ^[0-9]+$ ]]; then
  echo "::error::API 回應異常 (status=${status:-null}, buildid=${new:-null})"
  exit 1
fi

now=$(date +%s)
echo "目前 Build ID：$new"

if [[ ! -f "$STATE_FILE" ]]; then
  notify "✅ 監控已啟動，目前 Build ID：\`$new\`"
  commit_state "$new" "init build $new"
  exit 0
fi

old=$(jq -r '.buildid // empty' "$STATE_FILE")
if [[ "$old" == "$new" ]]; then
  echo "沒有變化"
  exit 0
fi

if [[ "$updated" =~ ^[0-9]+$ ]]; then updated_tw=$(tw_time "$updated"); else updated_tw="未知"; fi

notify "🚨 **桌面破壞神有更新！**
Steam Public Build ID：\`$old\` → \`$new\`
Steam 顯示更新時間：$updated_tw（台灣時間）
偵測時間：$(tw_time "$now")（台灣時間）
⚠️ 掛機中的遊戲可能已經中斷，請讓 Steam 更新後重新啟動遊戲。"

commit_state "$new" "build $old -> $new"
