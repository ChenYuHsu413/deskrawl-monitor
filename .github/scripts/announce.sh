#!/usr/bin/env bash
# 讀取 #官方公告 的新訊息，翻成繁體中文後透過 Webhook 轉發（Claude 優先，失敗改用 Gemini）。
# PREVIEW=true 時翻譯最新 2 則（或 PREVIEW_MESSAGE_ID 指定的那則）並以測試格式發送，不更新 state.json。
# PREVIEW_TEXT 有值時只翻譯這段文字並以測試格式發送，不讀頻道、不更新 state.json。
# 預覽依 PREVIEW_TARGET：test 發到 DISCORD_TEST_WEBHOOK_URL（未設定退回主 Webhook），main 發到主 Webhook。
set -euo pipefail

STATE_FILE=state.json
GLOSSARY_FILE=glossary.json
USERNAME="桌面破壞神更新監控"
CLAUDE_MODEL="${CLAUDE_MODEL:-claude-sonnet-5-5}"
GEMINI_MODEL="${GEMINI_MODEL:-gemini-3.5-flash-lite}"
MAX_PER_RUN=5
MAX_IMAGES=2
DOWNLOAD_MAX_BYTES=$((20 * 1024 * 1024))
B64_MAX_BYTES=$((4608 * 1024))  # 4.5MB，以 base64 編碼後計算
IMG_MAX_SIDE=1500
PREVIEW_TITLE="🧪 測試訊息（請忽略）"
PREVIEW_COLOR=$((0x95A5A6))
is_preview=false
WORK=$(mktemp -d)
IM=""  # ImageMagick 指令，有圖片要送時才由 ensure_im 偵測／安裝

: "${DISCORD_WEBHOOK_URL:?DISCORD_WEBHOOK_URL 未設定}"

read -r -d '' SYSTEM_PROMPT <<'PROMPT' || true
你是 Steam 掛機 ARPG《桌面破壞神：掛機ARPG》（Deskrawl: Idle ARPG）的官方公告翻譯。使用者會提供開發者公告的英文原文（可能附圖片）與發布時間，請翻成繁體中文。讀者是台灣玩家，英文不好，要讓他們一看就懂「要做什麼、什麼時候」。

遊戲背景：
- 已知系統：符文、符文轉化、裝備開光、排行榜。
- 1.1.0 版將推出寵物系統（培養僕從）、世界王、名人堂。

翻譯規則：
1. 意譯為主，使用自然的台灣用語，不要逐字直譯。
2. 必須遵守下方術語表。術語表只在該詞作為遊戲專有名詞時套用；一般英文用法（例如 grand prize、top tier、boss fight 的一般敘述）照正常語意翻譯。
3. 術語表裡已有的詞直接用中文譯名，不加星號、不加英文括號。術語表沒有的遊戲專有名詞（裝備名、技能名、狀態效果名等），譯成中文後在中文名稱後面加「*」，再附英文原文，格式為「中文*（English）」，例如「鐵暴君頭盔*（Iron Tyrant's Helm）」；不確定怎麼翻的就保留英文。
4. 只要譯文中出現至少一個「*」，就在譯文最後另起一行加上「* 暫定譯名，遊戲內名稱可能不同」；沒有就不加。
5. 數值寫法：原文的「+X%」照原樣保留為「+X%」；「X% more」譯成「增加 X%」，不要混用。
6. 日期時間一律換算成台灣時間（UTC+8），格式如「10/13（二）08:00–10:00」。美國太平洋時間要依日期判斷是 PDT（UTC-7）還是 PST（UTC-8）；文字中沒寫時區的時間視為美國太平洋時間。tomorrow、tonight、next week 等相對時間依「發布時間」推算。
7. 公告提到需要更新遊戲（update the client/game、patch、restart Steam 等）時，第一行加上「⚠️ 需要更新遊戲」。
8. 圖片中有文字（例如更新路線圖、維護時間、裝備說明）時，一併翻譯並整理成條列重點，職業限制和小字的效果說明也要翻譯，不要省略；圖片中的日期沒有時區時，照原文保留並註明「（官方未註明時區）」。
9. 結尾的客套語（Cheers!、Have fun!、Thanks! 等）譯成自然的「祝遊戲愉快！」或直接省略，不要譯成「加油！」。
10. 移除 @everyone、@here，不要產生任何 @ 提及；網址原樣保留。
11. 只輸出翻譯結果，不要加任何說明、前言或程式碼區塊。

術語表（英文 → 中文譯名）：
PROMPT
SYSTEM_PROMPT+=$'\n'$(jq -r 'to_entries[] | "- \(.key) → \(.value)"' "$GLOSSARY_FILE")

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

# 找 ImageMagick；沒有就安裝（同一次執行只嘗試一次，失敗不中斷，照原圖送）
ensure_im() {
  IM=$(command -v magick || command -v convert || true)
  [[ -n "$IM" || -f "$WORK/im_install_tried" ]] && return 0
  touch "$WORK/im_install_tried"
  echo "  找不到 ImageMagick，安裝中（apt-get install imagemagick）" >&2
  # 第一次失敗多半是套件清單過期，update 後再試一次
  if sudo apt-get install -y --no-install-recommends imagemagick > "$WORK/apt.log" 2>&1 ||
    { echo "  安裝失敗，執行 apt-get update 後重試" >&2
      sudo apt-get update > "$WORK/apt.log" 2>&1 &&
      sudo apt-get install -y --no-install-recommends imagemagick > "$WORK/apt.log" 2>&1; }; then
    IM=$(command -v magick || command -v convert || true)
    echo "  ImageMagick 安裝完成：${IM:-安裝後仍找不到指令}" >&2
  else
    echo "  ImageMagick 安裝失敗，照原圖送：$(tail -n 3 "$WORK/apt.log" | tr '\n' ' ')" >&2
  fi
}

# 下載圖片（最多 MAX_IMAGES 張），長邊超過 1500px 的縮小並一律轉成 JPEG（GIF 只取第一格）；
# base64 後超過 4.5MB 的略過。成功的寫入 $WORK/imgN.b64 與 $WORK/imgN.mime
# stdout 輸出成功的編號，log 走 stderr
download_images() {  # $@=圖片網址
  local k=0 url mime dims size
  rm -f "$WORK"/img*
  if [[ $# -gt 0 ]]; then
    ensure_im
    [[ -z "$IM" ]] && echo "  沒有 ImageMagick（magick/convert），略過縮圖、照原圖送" >&2
  fi
  for url in "$@"; do
    k=$((k + 1))
    if ! mime=$(curl -fsSL --max-time 30 --max-filesize "$DOWNLOAD_MAX_BYTES" -o "$WORK/img$k.orig" -w '%{content_type}' "$url"); then
      echo "  圖片 $k 下載失敗或超過 20MB，略過" >&2; continue
    fi
    mime=${mime%%;*}
    if [[ "$mime" != image/* ]]; then
      echo "  圖片 $k 類型為 ${mime:-未知}，略過" >&2; continue
    fi
    dims="未縮圖"
    cp "$WORK/img$k.orig" "$WORK/img$k"
    if [[ -n "$IM" ]]; then
      dims=$("$IM" "$WORK/img$k.orig[0]" -format '%wx%h' info: 2>/dev/null || echo "尺寸未知")
      # [0] 只取第一格（GIF）；透明背景補白色；'>' 只縮不放大
      if "$IM" "$WORK/img$k.orig[0]" -background white -flatten -resize "${IMG_MAX_SIDE}x${IMG_MAX_SIDE}>" \
        -quality 85 "jpg:$WORK/img$k.jpg" 2>/dev/null; then
        mv "$WORK/img$k.jpg" "$WORK/img$k"
        mime=image/jpeg
        dims+=" → $("$IM" "$WORK/img$k" -format '%wx%h' info: 2>/dev/null || echo "尺寸未知")"
      else
        echo "  圖片 $k 縮圖失敗，照原圖送" >&2
        dims+="（縮圖失敗）"
      fi
    fi
    base64 -w0 "$WORK/img$k" > "$WORK/img$k.b64"
    size=$(stat -c%s "$WORK/img$k.b64")
    if ((size > B64_MAX_BYTES)); then
      echo "  圖片 $k（$dims，base64 $size bytes）超過 4.5MB，略過" >&2; continue
    fi
    printf '%s' "$mime" > "$WORK/img$k.mime"
    echo "  圖片 $k（$dims，$mime，base64 $size bytes）送翻譯" >&2
    echo "$k"
  done
}

# 送出 $WORK/body.json，失敗重試 1 次；成功時 stdout 輸出翻譯結果
call_api() {  # $1=log 名稱 $2=jq 取翻譯 $3=jq 取錯誤訊息 $4...=curl 參數（含 key header，不可印出）
  local name=$1 pick=$2 err=$3 i code out
  shift 3
  for i in 1 2; do
    [[ $i -gt 1 ]] && sleep 15  # 模型忙碌（429/503/529）多半是暫時的，稍等再重試
    code=$(curl -sS --max-time 90 -o "$WORK/res.json" -w '%{http_code}' -d @"$WORK/body.json" "$@") || code=000
    out=$(jq -r "$pick" "$WORK/res.json" 2>/dev/null || true)
    if [[ "$code" == 200 && -n "$out" ]]; then printf '%s' "$out"; return 0; fi
    echo "  $name 第 $i 次失敗：HTTP $code $(jq -r "$err" "$WORK/res.json" 2>/dev/null || echo "連線失敗或回應無法解析")" >&2
  done
  return 1
}

# 依序嘗試 Claude、Gemini（沒設定 key 的跳過）；成功時把「供應商 / 模型」寫入 $WORK/provider
translate() {  # $1=原文 $2=發布時間 ISO 8601 $3...=已下載圖片編號
  local text=$1 ts=$2 pub user out k
  shift 2
  pub="發布時間：$(TZ=America/Los_Angeles date -d "$ts" '+%Y-%m-%d (%a) %H:%M %Z')，即台灣時間 $(TZ=Asia/Taipei date -d "$ts" '+%Y-%m-%d (%a) %H:%M')"
  user="$pub"$'\n\n公告原文：\n'"${text:-（本則公告只有圖片）}"

  if [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
    # Sonnet 5.5 不接受非預設 temperature（會回 400），所以不送；effort low 避免思考吃掉 max_tokens
    jq -n --arg m "$CLAUDE_MODEL" --arg sys "$SYSTEM_PROMPT" \
      '{model: $m, max_tokens: 2000, output_config: {effort: "low"}, system: $sys, messages: [{role: "user", content: []}]}' \
      > "$WORK/body.json"
    # base64 可能很大，用檔案傳給 jq 避免超過命令列長度限制；圖片放在文字之前
    for k in "$@"; do
      jq --rawfile d "$WORK/img$k.b64" --rawfile m "$WORK/img$k.mime" \
        '.messages[0].content += [{type: "image", source: {type: "base64", media_type: $m, data: $d}}]' "$WORK/body.json" > "$WORK/body.tmp"
      mv "$WORK/body.tmp" "$WORK/body.json"
    done
    jq --arg u "$user" '.messages[0].content += [{type: "text", text: $u}]' "$WORK/body.json" > "$WORK/body.tmp"
    mv "$WORK/body.tmp" "$WORK/body.json"
    # 只收完整結束的回應（被 max_tokens 截斷或拒答都算失敗）
    if out=$(call_api "Claude（$CLAUDE_MODEL）" \
      'if .stop_reason == "end_turn" then [.content[]? | select(.type == "text") | .text] | join("") else empty end' \
      '.error.message // "stop_reason=\(.stop_reason // "無")"' \
      -H "x-api-key: $ANTHROPIC_API_KEY" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' \
      https://api.anthropic.com/v1/messages); then
      printf '%s' "Claude / $CLAUDE_MODEL" > "$WORK/provider"
      printf '%s' "$out"
      return 0
    fi
  else
    echo "  未設定 ANTHROPIC_API_KEY，略過 Claude" >&2
  fi

  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    jq -n --arg sys "$SYSTEM_PROMPT" --arg u "$user" \
      '{systemInstruction: {parts: [{text: $sys}]}, contents: [{role: "user", parts: [{text: $u}]}], generationConfig: {temperature: 0.3}}' \
      > "$WORK/body.json"
    for k in "$@"; do
      jq --rawfile d "$WORK/img$k.b64" --rawfile m "$WORK/img$k.mime" \
        '.contents[0].parts += [{inline_data: {mime_type: $m, data: $d}}]' "$WORK/body.json" > "$WORK/body.tmp"
      mv "$WORK/body.tmp" "$WORK/body.json"
    done
    if out=$(call_api "Gemini（$GEMINI_MODEL）" \
      '[.candidates[0].content.parts[]? | select(.thought != true) | .text // empty] | join("")' \
      '.error.message // "無翻譯內容"' \
      -H "x-goog-api-key: $GEMINI_API_KEY" -H 'Content-Type: application/json' \
      "https://generativelanguage.googleapis.com/v1beta/models/${GEMINI_MODEL}:generateContent"); then
      printf '%s' "Gemini / $GEMINI_MODEL" > "$WORK/provider"
      printf '%s' "$out"
      return 0
    fi
  else
    echo "  未設定 GEMINI_API_KEY，略過 Gemini" >&2
  fi
  return 1
}

post() {  # $1=標題 $2=內文 $3=發布時間 $4=原圖網址（可空）$5=翻譯供應商（可空）
  local footer="原文發布：$(TZ=Asia/Taipei date -d "$3" '+%Y-%m-%d %H:%M')（台灣時間）"
  local user=$USERNAME desc=$2 color=null flags=null webhook=$DISCORD_WEBHOOK_URL
  [[ -n "${5:-}" ]] && footer+=" · 翻譯：$5"
  # 預覽一律用測試格式（灰色、標註測試），與正式公告區分
  if [[ "$is_preview" == true ]]; then
    user="$USERNAME（測試）"
    desc="⚠️ 這是測試翻譯，不是新的官方公告"$'\n\n'"$2"
    color=$PREVIEW_COLOR
    flags=4096  # SUPPRESS_NOTIFICATIONS：靜音、不推播
    if [[ "${PREVIEW_TARGET:-test}" != main && -n "${DISCORD_TEST_WEBHOOK_URL:-}" ]]; then
      webhook=$DISCORD_TEST_WEBHOOK_URL
      echo "  預覽發送到測試 Webhook"
    else
      echo "  預覽發送到主 Webhook"
    fi
  fi
  local payload
  payload=$(jq -n --arg u "$user" --arg t "$1" --arg d "$desc" --arg f "$footer" --arg img "${4:-}" --argjson c "$color" --argjson fl "$flags" '{
      username: $u,
      allowed_mentions: {parse: []},
      embeds: [{title: $t, description: (if ($d | length) > 3500 then $d[0:3500] + "…" else $d end), footer: {text: $f}}
        + (if $img != "" then {image: {url: $img}} else {} end)
        + (if $c != null then {color: $c} else {} end)]
    } + (if $fl != null then {flags: $fl} else {} end)')
  [[ "$is_preview" == true ]] && echo "  靜音發送：$(jq -r 'if .flags == 4096 then "是" else "否" end' <<<"$payload")"
  curl -fsS --retry 3 --max-time 20 -H 'Content-Type: application/json' -d @- "$webhook" <<<"$payload" >/dev/null
}

# 只處理一般訊息（type 0）與回覆（type 19），追蹤頻道等系統訊息視為空內容
# 本體與轉發訊息的 snapshot 一起看
sources='if (.type != 0 and .type != 19) then empty else (., .message_snapshots[]?.message) end'

# 訊息內文：content + embeds 的 title/description
extract="[$sources | .content, (.embeds[]? | .title, .description)]
  | map(select(. != null and . != \"\")) | join(\"\\n\\n\")"

# 圖片網址：attachments 中 image/*，以及 embed 的 image/thumbnail
images="[$sources | (.attachments[]? | select((.content_type // \"\") | startswith(\"image/\")) | .url),
  (.embeds[]? | .image.url, .thumbnail.url)] | map(select(. != null))"

# log 用：type、flags、是否轉發（message_reference.type 1 或有 snapshot）、是否追蹤轉來（IS_CROSSPOST 或 webhook）
describe='"type=\(.type) flags=\(.flags // 0) 轉發=\(if .message_reference.type == 1 or ((.message_snapshots // []) | length > 0) then "是" else "否" end) 追蹤=\(if (((.flags // 0) / 2 | floor) % 2 == 1) or .webhook_id != null then "是" else "否" end)"'

# 依時間由舊到新排序（snowflake 太大不能轉數字，先比長度再比字串）
sort_old_first='sort_by((.id | length), .id)'

# 翻譯並推播一則公告
forward() {  # $1=標題 $2=原文 $3=發布時間 $4...=圖片網址
  local title=$1 text=$2 ts=$3 out ok_imgs provider=""
  shift 3
  mapfile -t ok_imgs < <(download_images "$@")
  rm -f "$WORK/provider"
  if out=$(translate "$text" "$ts" "${ok_imgs[@]}"); then
    provider=$(cat "$WORK/provider")
  else
    out="（翻譯失敗，以下為原文）"$'\n'"$text"
  fi
  # 暫定譯名的「*」要跳脫，否則兩個星號之間會被 Discord 當成斜體
  out=$(sed -E -e 's/@(everyone|here)//g' -e 's/[*](（|[(])/\\*\1/g' -e 's/^[*] 暫定譯名/\\* 暫定譯名/' <<<"$out")
  post "$title" "$out" "$ts" "${1:-}" "$provider" || return 1
  echo "  → 已轉發（翻譯：${provider:-失敗，發原文}）"
}

process() {  # $1=標題 $2=是否更新狀態
  local n i msg id ts text img_urls
  n=$(jq 'length' <<<"$msgs")
  for ((i = 0; i < n; i++)); do
    msg=$(jq -c ".[$i]" <<<"$msgs")
    id=$(jq -r '.id' <<<"$msg")
    ts=$(jq -r '.timestamp' <<<"$msg")
    text=$(jq -r "$extract" <<<"$msg" | sed -E 's/@(everyone|here)//g')
    mapfile -t img_urls < <(jq -r "$images | .[0:$MAX_IMAGES][]" <<<"$msg")
    echo "訊息 $id $(jq -r "$describe" <<<"$msg") 圖片=${#img_urls[@]} 內容：$(jq -rn --arg t "$text" '$t | gsub("\\s+"; " ") | .[0:50]')"
    if [[ -z "${text//[[:space:]]/}" && ${#img_urls[@]} -eq 0 ]]; then
      echo "  → 跳過：沒有文字也沒有圖片（系統訊息或空訊息）"
    elif ! forward "$1" "$text" "$ts" "${img_urls[@]}"; then
      echo "::error::推播訊息 $id 失敗"
      return 1
    fi
    [[ "$2" == true ]] && save_state "$id"
  done
  return 0
}

if [[ -n "${PREVIEW_TEXT:-}" ]]; then
  is_preview=true
  echo "預覽指定文字：$(jq -rn --arg t "$PREVIEW_TEXT" '$t | gsub("\\s+"; " ") | .[0:50]')"
  forward "$PREVIEW_TITLE" "$(sed -E 's/@(everyone|here)//g' <<<"$PREVIEW_TEXT")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ||
    { echo "::error::推播預覽失敗"; exit 1; }
  exit 0
fi

: "${DISCORD_BOT_TOKEN:?DISCORD_BOT_TOKEN 未設定}"
: "${ANNOUNCE_CHANNEL_ID:?ANNOUNCE_CHANNEL_ID 未設定}"

if [[ "${PREVIEW:-false}" == true ]]; then
  is_preview=true
  if [[ -n "${PREVIEW_MESSAGE_ID:-}" ]]; then
    fetch "around=${PREVIEW_MESSAGE_ID}&limit=1"
    msgs=$(jq --arg id "$PREVIEW_MESSAGE_ID" 'map(select(.id == $id))' <<<"$msgs")
    [[ $(jq length <<<"$msgs") -eq 0 ]] && echo "找不到訊息 $PREVIEW_MESSAGE_ID"
  else
    fetch "limit=20"
    msgs=$(jq "map(select(($extract) != \"\" or ($images | length) > 0)) | $sort_old_first | .[-2:]" <<<"$msgs")
    [[ $(jq length <<<"$msgs") -eq 0 ]] && echo "頻道內沒有可預覽的公告（系統訊息不算）"
  fi
  process "$PREVIEW_TITLE" false
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
echo "last_announce_msg_id=$last，新訊息 $(jq length <<<"$msgs") 則"
rc=0
process "📢 官方公告" true || rc=1
commit_if_changed "announce -> $(jq -r '.last_announce_msg_id' "$STATE_FILE")"
exit $rc
