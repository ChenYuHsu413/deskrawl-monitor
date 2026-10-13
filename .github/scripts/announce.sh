#!/usr/bin/env bash
# 讀取 #官方公告 的新訊息，用 Gemini 翻成繁體中文後透過 Webhook 轉發。
# PREVIEW=true 時翻譯最新 2 則並以預覽標題發送，不更新 state.json。
set -euo pipefail

STATE_FILE=state.json
USERNAME="桌面破壞神更新監控"
MODEL="${GEMINI_MODEL:-gemini-3.5-flash-lite}"
MAX_PER_RUN=5

: "${DISCORD_BOT_TOKEN:?DISCORD_BOT_TOKEN 未設定}"
: "${ANNOUNCE_CHANNEL_ID:?ANNOUNCE_CHANNEL_ID 未設定}"
: "${GEMINI_API_KEY:?GEMINI_API_KEY 未設定}"
: "${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL 未設定}"

read -r -d '' SYSTEM_PROMPT <<'PROMPT' || true
你是遊戲《Deskrawl: Idle ARPG》（中文名《桌面破壞神：掛機ARPG》）的官方公告翻譯。把使用者提供的英文公告翻成繁體中文，規則：
1. 使用自然的台灣用語，意譯而非逐字直譯；遊戲專有名詞可保留英文。
2. 原文中所有日期時間（PDT、PST、UTC、ET 等）都換算成台灣時間（UTC+8），格式如「10/13（二）08:00–10:00」。tomorrow、tonight、today 等相對時間依「發布時間」判斷；沒寫時區的時間視為美國太平洋時間，並依發布日期判斷當時是 PDT 還是 PST。
3. 若公告提到需要更新用戶端／遊戲（update the client/game、patch、restart Steam 等），在第一行加上「⚠️ 需要更新遊戲」。
4. 刪除 @everyone、@here，不要產生任何 @ 提及。
5. 網址原樣保留。
6. 只輸出翻譯結果，不要加任何說明、前言或程式碼區塊。
PROMPT

state=$(cat "$STATE_FILE" 2>/dev/null || echo '{}')
last=$(jq -r '.last_announce_msg_id // empty' <<<"$state")

discord_get() {
  curl -fsS --retry 2 --max-time 20 -H "Authorization: Bot $DISCORD_BOT_TOKEN" \
    "https://discord.com/api/v10/channels/${ANNOUNCE_CHANNEL_ID}/messages?$1"
}

# 讀取失敗只記 log，不發通知、不讓 workflow 失敗
fetch() {
  if ! msgs=$(discord_get "$1"); then
    echo "::error::讀取 Discord 公告頻道失敗（檢查 Bot token、頻道 ID 與權限）"
    exit 0
  fi
}

save_state() { jq --arg id "$1" '.last_announce_msg_id = $id' <<<"$state" > "$STATE_FILE"; state=$(cat "$STATE_FILE"); }

commit_if_changed() {
  git diff --quiet -- "$STATE_FILE" && return 0
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add "$STATE_FILE"
  git commit -q -m "$1"
  git push -q
}

translate() {  # $1=原文 $2=發布時間 ISO 8601
  local pub body res text i
  pub="發布時間：$(TZ=America/Los_Angeles date -d "$2" '+%Y-%m-%d (%a) %H:%M %Z')，即台灣時間 $(TZ=Asia/Taipei date -d "$2" '+%Y-%m-%d (%a) %H:%M')"
  body=$(jq -n --arg sys "$SYSTEM_PROMPT" --arg u "$pub"$'\n\n公告原文：\n'"$1" \
    '{systemInstruction: {parts: [{text: $sys}]}, contents: [{role: "user", parts: [{text: $u}]}], generationConfig: {temperature: 0.3}}')
  for i in 1 2; do
    [[ $i -gt 1 ]] && sleep 15  # 模型忙碌（503）多半是暫時的，稍等再重試
    if res=$(curl -sS --max-time 90 -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' -d "$body" \
        "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent"); then
      text=$(jq -r '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")' <<<"$res" 2>/dev/null || true)
      if [[ -n "$text" ]]; then printf '%s' "$text"; return 0; fi
      echo "Gemini 第 $i 次失敗：$(jq -r '.error.message // "無翻譯內容"' <<<"$res" 2>/dev/null || echo "回應無法解析")" >&2
    else
      echo "Gemini 第 $i 次連線失敗" >&2
    fi
  done
  return 1
}

post() {  # $1=標題 $2=內文 $3=發布時間
  local footer="原文發布：$(TZ=Asia/Taipei date -d "$3" '+%Y-%m-%d %H:%M')（台灣時間）"
  jq -n --arg u "$USERNAME" --arg t "$1" --arg d "$2" --arg f "$footer" '{
      username: $u,
      allowed_mentions: {parse: []},
      embeds: [{title: $t, description: (if ($d | length) > 3500 then $d[0:3500] + "…" else $d end), footer: {text: $f}}]
    }' |
    curl -fsS --retry 3 --max-time 20 -H 'Content-Type: application/json' -d @- "$DISCORD_WEBHOOK_URL" >/dev/null
}

# 訊息內文：content + embeds 的 title/description（含轉發訊息的 snapshot）
# 只處理一般訊息（type 0）與回覆（type 19），追蹤頻道等系統訊息視為空內容
extract='if (.type != 0 and .type != 19) then "" else
  [.content, (.embeds[]? | .title, .description),
  (.message_snapshots[]?.message | .content, (.embeds[]? | .title, .description))]
  | map(select(. != null and . != "")) | join("\n\n") end'

# 依時間由舊到新排序（snowflake 太大不能轉數字，先比長度再比字串）
sort_old_first='sort_by((.id | length), .id)'

process() {  # $1=標題 $2=是否更新狀態
  local n i id ts text out
  n=$(jq 'length' <<<"$msgs")
  for ((i = 0; i < n; i++)); do
    id=$(jq -r ".[$i].id" <<<"$msgs")
    ts=$(jq -r ".[$i].timestamp" <<<"$msgs")
    text=$(jq -r ".[$i] | $extract" <<<"$msgs" | sed -E 's/@(everyone|here)//g')
    if [[ -z "${text//[[:space:]]/}" ]]; then
      echo "訊息 $id 內容為空，跳過"
    else
      if ! out=$(translate "$text" "$ts"); then
        out="（翻譯失敗，以下為原文）"$'\n'"$text"
      fi
      out=$(sed -E 's/@(everyone|here)//g' <<<"$out")
      if ! post "$1" "$out" "$ts"; then
        echo "::error::推播訊息 $id 失敗"
        return 1
      fi
      echo "已轉發訊息 $id"
    fi
    [[ "$2" == true ]] && save_state "$id"
  done
  return 0
}

if [[ "${PREVIEW:-false}" == true ]]; then
  fetch "limit=20"
  msgs=$(jq "map(select(($extract) != \"\")) | $sort_old_first | .[-2:]" <<<"$msgs")
  [[ $(jq length <<<"$msgs") -eq 0 ]] && echo "頻道內沒有可預覽的公告（系統訊息不算）"
  process "📢 官方公告（預覽）" false
  exit
fi

if [[ -z "$last" ]]; then
  fetch "limit=1"
  id=$(jq -r '.[0].id // empty' <<<"$msgs")
  if [[ -z "$id" ]]; then echo "公告頻道目前沒有訊息"; exit 0; fi
  save_state "$id"
  commit_if_changed "init announce $id"
  echo "初始化 last_announce_msg_id=$id"
  exit 0
fi

fetch "after=${last}&limit=20"
msgs=$(jq "$sort_old_first | .[0:$MAX_PER_RUN]" <<<"$msgs")
echo "新訊息 $(jq length <<<"$msgs") 則"
rc=0
process "📢 官方公告" true || rc=1
commit_if_changed "announce -> $(jq -r '.last_announce_msg_id' "$STATE_FILE")"
exit $rc
