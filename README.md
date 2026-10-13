# deskrawl-monitor

用 GitHub Actions 監控 Steam 遊戲《桌面破壞神：掛機ARPG》(App ID `4623570`)，包含兩個互相獨立的功能（一個失敗不影響另一個）：

1. **Build ID 監控**：public branch Build ID 有變化時推播到 Discord。
   - 資料來源：`https://api.steamcmd.net/v1/info/4623570`
   - 程式：`.github/scripts/check.sh`
2. **官方公告翻譯轉發**：讀取 Discord #官方公告 頻道的新訊息，用 Gemini 翻成繁體中文後轉發（見第 6 節）。
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
每次排程執行時，Bot 會讀取該頻道的新訊息，交給 Gemini 翻成繁體中文（日期時間換算成台灣時間），
再以 embed「📢 官方公告」發到 `DISCORD_WEBHOOK_URL` 的頻道。

### 需要的 Secrets（Settings → Secrets and variables → Actions → Secrets）

| 名稱 | 說明 |
| --- | --- |
| `DISCORD_WEBHOOK_URL` | 通知頻道的 Webhook（與 Build ID 監控共用） |
| `DISCORD_BOT_TOKEN` | 自己的 Discord Bot token |
| `ANNOUNCE_CHANNEL_ID` | #官方公告 頻道 ID（Discord 開啟開發者模式 → 對頻道按右鍵 → 複製頻道 ID） |
| `GEMINI_API_KEY` | Google AI Studio 的 Gemini API key（免費額度即可） |

選用的 Variable（同頁面 → Variables 分頁）：`GEMINI_MODEL`，未設定時預設 `gemini-3.8-flash`。
若之後該模型下架或免費額度用完，改填其他 Flash 系列模型名稱即可，不用改程式。

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
- Gemini 翻譯失敗會重試 1 次，仍失敗就改發原文（前面加「（翻譯失敗，以下為原文）」）。
- 讀取 Discord 頻道失敗只會在 log 記錯誤，不會發通知。
- 發送時設定 `allowed_mentions: {"parse": []}`，並移除 `@everyone`、`@here`，不會 @ 到任何人。

### 預覽翻譯效果

Actions → **Monitor Steam Build** → **Run workflow** → 勾選 **preview_announce** → **Run workflow**。
會把 #官方公告 最新 2 則翻譯後以「📢 官方公告（預覽）」發送，**不會**更新 `state.json`。
