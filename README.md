# deskrawl-monitor

用 GitHub Actions 監控 Steam 遊戲《桌面破壞神：掛機ARPG》(App ID `4623570`)，包含兩個互相獨立的功能（一個失敗不影響另一個）：

1. **Build ID 監控**：public branch Build ID 有變化時推播到 Discord。
   - 資料來源：`https://api.steamcmd.net/v1/info/4623570`
   - 程式：`.github/scripts/check.sh`
2. **官方公告翻譯轉發**：讀取 Discord #官方公告 頻道的新訊息，用 Claude（失敗時改用 Gemini）翻成繁體中文後轉發（見第 6 節）。
   - 程式：`.github/scripts/announce.sh`

- 狀態檔：`state.json`（`buildid`、`last_announce_msg_id`；推播成功後才會 commit 更新）
- 排程：`.github/workflows/monitor.yml`

## 1. 設定 Discord Webhook

1. Discord 頻道 → 編輯頻道 → 整合 → Webhook → 新 Webhook → 複製 Webhook 網址。
2. 到本 repo 的 **Settings → Secrets and variables → Actions**。
3. 按 **New repository secret**：
   - Name：`DISCORD_WEBHOOK_URL`
   - Secret：貼上 Webhook 網址
4. 按 **Add secret**。

> Webhook 網址等同發訊權限，請勿寫進程式碼或公開。

## 2. 手動觸發測試

1. 到 repo 的 **Actions** 分頁。
2. 左側選 **Monitor Steam Build**。
3. 右側按 **Run workflow** → **Run workflow**。
4. 點進執行紀錄查看 log：
   - Build ID 沒變：顯示「沒有變化」，不會發通知、不會 commit。
   - Build ID 改變：發 Discord 通知，並 commit `state.json`（訊息如 `build 25895065 -> 25912345`）。

想測試「有更新」通知：把 `state.json` 的 `buildid` 改成別的數字並 commit，再手動觸發一次。
想測試「監控已啟動」通知：刪掉 `state.json` 並 commit，再手動觸發。

## 3. 排程說明

GitHub Actions 的 cron 一律是 **UTC**，台灣時間 = UTC+8。目前排程（台灣時間）：

| 時段 | 頻率 |
| --- | --- |
| 每天 06:30–07:00 | 約每 10 分鐘（06:32、06:42、06:52） |
| 每天 07:00–16:00 | 約每 15 分鐘（:07、:22、:37、:52） |
| 每天 17:30–19:00 | 約每 15 分鐘（17:37 起到 18:52） |

注意：

- GitHub 排程是盡力而為，**實際執行常延遲 5–20 分鐘**，尖峰時段甚至可能被跳過。
- 刻意避開整點（:00），整點是 GitHub 排程最擁擠的時候。
- 各條 cron 對應的台灣時間寫在 `monitor.yml` 的註解裡。

## 4. 60 天沒活動會自動停用

公開 repo 若 **60 天內沒有任何 commit 等活動**，GitHub 會自動停用排程 workflow（會先寄信通知）。
因為只有遊戲更新時才會 commit，長時間沒更新就可能被停用。

重新啟用：

1. 到 **Actions** 分頁 → 左側選 **Monitor Steam Build**。
2. 上方會出現停用提示，按 **Enable workflow**。

## 5. 停用或移除

- **暫時停用**：Actions → Monitor Steam Build → 右上角 `…` → **Disable workflow**。要恢復時按 **Enable workflow**。
- **只停排程、保留手動觸發**：刪掉 `monitor.yml` 中的 `schedule:` 區塊。
- **完全移除**：Settings → 最下方 Danger Zone → **Delete this repository**；並到 Discord 頻道整合設定刪除該 Webhook。

## 6. 官方公告翻譯轉發

用 Discord 的「追蹤」功能把官方（Deskrawl: Idle ARPG）公告接到自己伺服器的 #官方公告 頻道，
每次排程執行時，Bot 會讀取該頻道的新訊息，交給 Claude（失敗時改用 Gemini）翻成繁體中文（日期時間換算成台灣時間），
再以 embed「📢 官方公告」發到 `DISCORD_WEBHOOK_URL` 的頻道。

### 需要的 Secrets（Settings → Secrets and variables → Actions → Secrets）

| 名稱 | 說明 |
| --- | --- |
| `DISCORD_WEBHOOK_URL` | 通知頻道的 Webhook（與 Build ID 監控共用） |
| `DISCORD_BOT_TOKEN` | 自己的 Discord Bot token |
| `ANNOUNCE_CHANNEL_ID` | #官方公告 頻道 ID（Discord 開啟開發者模式 → 對頻道按右鍵 → 複製頻道 ID） |
| `ANTHROPIC_API_KEY` | Claude API key（[Claude Console](https://console.anthropic.com/) → API Keys），主要翻譯供應商 |
| `GEMINI_API_KEY` | Google AI Studio 的 Gemini API key（免費額度即可），Claude 失敗時的備援 |

兩個翻譯 key 都是選用：沒設定的供應商會直接跳過；兩個都沒設定就一律發原文。

選用的 Variables（同頁面 → Variables 分頁），改模型不用改程式：

| 名稱 | 預設 | 說明 |
| --- | --- | --- |
| `CLAUDE_MODEL` | `claude-sonnet-5-5` | Claude 模型 ID |
| `GEMINI_MODEL` | `gemini-3.5-flash-lite` | Gemini 模型（免費額度較寬，實測 `gemini-3.8-flash` 在免費額度常回「需求量過高」） |

### 翻譯供應商順序

1. **Claude**（`CLAUDE_MODEL`）：失敗重試 1 次（間隔 15 秒）。回應被截斷或拒答也算失敗。
2. **Gemini**（`GEMINI_MODEL`）：Claude 仍失敗才使用，同樣重試 1 次。
3. 兩者都失敗才發原文（前面加「（翻譯失敗，以下為原文）」）。

通知 embed 的 footer 會標示實際使用的供應商與模型，例如
「原文發布：2026-10-21 06:12（台灣時間）· 翻譯：Claude / claude-sonnet-5-5」。

### 術語表 `glossary.json`

repo 根目錄的 `glossary.json` 是 `{"英文術語": "中文譯名"}` 格式，每次執行時讀入翻譯提示，Claude 與 Gemini 共用。
初始內容取自 Steam 官方 patch notes 繁中版與英文版的對照。

- 新增或修改譯名：直接編輯檔案並 commit，下次執行就生效。
- 同一個詞的單複數或大小寫寫法差很多時（例如 `minion` / `minions`），可以各列一筆。
- 必須是合法 JSON（最後一筆後面不能有逗號），格式錯誤會讓公告轉發步驟失敗；可用 `jq . glossary.json` 檢查。
- 術語表沒有的專有名詞，模型會譯成中文並在括號附英文原文，例如「韁繩（Reins）」；看到翻得不好的就補進術語表。

### Bot 設定

1. [Discord Developer Portal](https://discord.com/developers/applications) → 你的應用程式 → **Bot**：
   開啟 **Message Content Intent**（沒開的話讀不到訊息內文）。
2. 把 Bot 邀請進伺服器，並確認它在 #官方公告 頻道有：
   - **View Channels**（檢視頻道）
   - **Read Message History**（讀取訊息歷史）
3. Bot 不需要發言權限，通知是透過 Webhook 發送。

### 運作方式

- 第一次執行（`state.json` 沒有 `last_announce_msg_id`）只記錄頻道目前最新一則訊息的 ID，不翻譯、不通知。
- 之後每次執行，依時間由舊到新處理新訊息，一次最多 5 則（剩下的下次再處理）。
- 每則推播成功才更新 `last_announce_msg_id`；推播失敗會讓這個步驟失敗，下次從失敗那則重試。
- 翻譯失敗的處理見上方「翻譯供應商順序」。
- 讀取 Discord 頻道失敗只會在 log 記錯誤，不會發通知。
- 支援 Discord「轉發」的訊息（內容在 `message_snapshots`）與追蹤功能轉來的訊息；系統訊息（例如追蹤頻道的提示）會跳過。
- 圖片公告：訊息（含轉發內容、embed）中的圖片最多取 2 張、每張超過 4MB 略過，連同文字送給翻譯模型翻譯圖中文字；通知的 embed 會附上原圖。
- log 會列出每則訊息的 ID、type、flags、是否轉發、內容前 50 字與處理結果；Claude／Gemini 失敗時會印出 HTTP 狀態碼與錯誤訊息（不會印出 key）。
- 發送時設定 `allowed_mentions: {"parse": []}`，並移除 `@everyone`、`@here`，不會 @ 到任何人。

### 預覽翻譯效果

Actions → **Monitor Steam Build** → **Run workflow** → 勾選 **preview_announce** → **Run workflow**。
會把 #官方公告 最新 2 則翻譯後以「📢 官方公告（預覽）」發送，**不會**更新 `state.json`。

要測試特定文字的翻譯效果：**Run workflow** → 在 **preview_text** 貼上英文原文 → **Run workflow**。
只會翻譯這段文字並以「📢 官方公告（預覽）」發送，不讀頻道、不更新 `state.json`（發布時間以執行當下計算）。
