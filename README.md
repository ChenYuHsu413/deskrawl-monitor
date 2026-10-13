# deskrawl-monitor

用 GitHub Actions 監控 Steam 遊戲《桌面破壞神：掛機ARPG》(App ID `4623570`) 的 public branch Build ID，有變化時推播到 Discord。

- 資料來源：`https://api.steamcmd.net/v1/info/4623570`
- 狀態檔：`state.json`（只有 Build ID 改變且 Discord 推播成功後才會 commit 更新）
- 主程式：`.github/scripts/check.sh`；排程：`.github/workflows/monitor.yml`

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
