# Windows 10/11 x64（PC125）

Python 3.12 托盤 MVP；不需 Node、Visual Studio、管理員權限或付費簽署。macOS Swift app 獨立保留。支援 OpenAI、Groq + Cloudflare，以及 ChatGPT plan SIWC 潤飾（預設 Groq STT）。

## PC125 安裝／啟動

已安裝 Git、Python 3.12 **x64**。在普通 PowerShell 執行（首次 clone 到自己的使用者目錄）：

```powershell
cd $HOME
git clone https://github.com/danoops/typeless-alt.git
cd typeless-alt
.\windows\run.bat
```

之後每次只需 **`.\windows\run.bat`**（亦可 Explorer 雙擊）。它以目前腳本位置執行、自動建立 `windows\.venv`、安裝固定版本 wheels，再啟動 tray；首次需 Internet。不需 activate venv；PowerShell execution policy 只對啟動子程序設定 Bypass，不修改系統政策。保持 console 開啟；從 tray → Quit 正常退出。不要以管理員執行。

如果 Python 沒有 launcher，script 會用 PATH 的 `python`；若有 `py`，須 `py -3.12` 可執行。執行 `py -3.12 -c "import struct; print(struct.calcsize('P')*8)"` 應顯示 `64`。

## 首次設定

啟動後右下角通知區（可能在 `^` 隱藏圖示內）右鍵麥克風圖示：

1. **Set credentials...** → 輸入 `OPENAI_API_KEY` 或 `GROQ_API_KEY` 等名稱，再輸入 secret。存於目前 Windows 使用者的 **Credential Manager**，不寫入 repo／JSON。亦可使用同名環境變數，環境變數優先；app 必須在設好環境的 shell 啟動。
2. **Open settings.json** → 編輯 `%LOCALAPPDATA%\typeless-alt\settings.json`，儲存後 **Reload settings**。
3. Windows Settings → Privacy（Windows 11：Privacy & security）→ Microphone → 允許 microphone access 及 **desktop apps** 存取。Sound → Input 選擇麥克風。
4. 在 Notepad 普通文字欄位放好游標，按 **Ctrl+Alt+D** 開始，說話，再按一次停止。圖示藍色＝閒置、紅色＝錄音、橙色＝處理中。最多 180 秒。取消用 tray → Cancel recording，不送 API。
5. 保持原欄位／視窗焦點；完成後 clipboard + Windows **SendInput Ctrl+V** 貼上，不按 Enter。發送前核對人名、數字、語意。若失敗或焦點改變，用 **Copy last result** 自行貼上；潤飾失敗時最後結果是原始逐字稿，不會自動貼上。

### A. OpenAI API

預設 `backend: "openai"`，只需 `OPENAI_API_KEY`。STT `gpt-4o-transcribe`，潤飾 `gpt-4o-mini`；使用獨立 API billing。

### B. Groq + Cloudflare

`backend` 改 `"groq-cf"`，加入 `GROQ_API_KEY`。二選一：

- REST：設定 `cloudflareAccountID`（32 hex）及 Credential Manager `CF_API_TOKEN`（Workers AI 權限）。
- 已部署本 repo 的 `worker/`：設定 `cloudflareWorkerURL`（可信任 HTTPS URL），加入 `CF_WORKER_TOKEN`（等於 Worker 的 `WORKER_SECRET`），無需帳戶 token。沿用根目錄 README 的 Worker 部署步驟。

亦支援 `CF_ACCOUNT_ID`、`CF_WORKER_URL` 環境變數。逐字稿送到所選 Cloudflare endpoint；免費額度以供應商帳戶為準，無收費後端自動 fallback。

### C. ChatGPT plan / SIWC

設定 `backend: "chatgpt-plan"`、`chatgptSTT: "groq"`，加入 `GROQ_API_KEY`，Reload settings，再選 **Continue with ChatGPT**。系統瀏覽器開啟 OpenAI 登入及授權，以 `127.0.0.1` 隨機 port 接收 callback（只 listen loopback，五分鐘逾時）。完成後會通知登入結果。不要公開 callback URL；無需開放 LAN／router port。

此 port 實作 Authorization Code + PKCE S256、state／nonce、已發行 client ID 綁定、RS256 ID token 簽署／issuer／audience／expiry 驗證、refresh token 輪換、sign out 撤銷。單帳戶 MVP；換帳戶先 Sign out。host ID／client ID 保留供重登；token 只存目前使用者 DPAPI 加密的 `%LOCALAPPDATA%\typeless-alt\siwc.dpapi`（token set 可超過 Credential Manager blob 容量），與 Mac Keychain 分開，不匯入 Codex 或其他 app tokens。登入／處理時拒絕再次錄音，單實例 lock 防止 refresh 競爭。

合資格帳戶及 workspace 必須允許 SIWC plan usage。潤飾使用公開 `/v1/models` 的可見模型和 `/v1/responses`（`store:false`, `stream:true`），只接受 completed assistant output。缺少 scope、額度不足、stream 中斷都不自動貼上，沒有 API key billing fallback。

**SIWC 不提供這條 audio/transcriptions 路徑的授權：STT 預設仍是 Groq**，並非用 ChatGPT 訂閱做錄音轉錄。亦可明確改 `chatgptSTT: "openai"`，自行提供 `OPENAI_API_KEY` 及 API billing。若帳戶不能完成 SIWC，請改 `groq-cf` 並提供 Cloudflare 憑證；不會自動改供應商。真實 Windows browser 授權／帳戶資格須在 PC125 手動驗收。

參考 [OpenAI SIWC 登入](https://developers.openai.com/siwc/token-sharing-open-source/sign-in)、[session](https://developers.openai.com/siwc/token-sharing-open-source/profiles-and-sessions)。

## 設定對照

JSON 自動合併缺少欄位的預設值；key 名稱盡量與 Mac `settings.plist` 相同。無需／不讀取 Mac plist。例：

```json
{
  "backend": "chatgpt-plan",
  "chatgptSTT": "groq",
  "chatgptModel": "",
  "hotkey": "ctrl+alt+d",
  "sounds": true,
  "historyLimit": 0
}
```

| key | 預設／用途 |
| --- | --- |
| `backend` | `openai` / `groq-cf` / `chatgpt-plan` |
| `chatgptSTT` | `groq` / `openai`（只限 plan 模式） |
| `chatgptModel` | 空字串＝帳戶第一個可見模型，或明確 slug |
| `transcriptionModel` | `gpt-4o-transcribe` |
| `polishModel` | `gpt-4o-mini` |
| `groqModel` | `whisper-large-v3` |
| `cloudflareModel` | `@cf/qwen/qwen3-30b-a3b-fp8`，Worker 模式由 Worker 決定 |
| `cloudflareAccountID` / `cloudflareWorkerURL` | 空字串 |
| `hotkey` | `ctrl+alt+d`；ctrl/alt/shift/win + 單一 A-Z/0-9；取代 Mac keyCode/modifiers |
| `sounds` | `true`；提示音可能被收錄，可設 false |
| `historyLimit` | `0` 關閉；1–500 存於同目錄 history.json；改回 0 不刪除舊歷史 |
| `inputDevice` | `null`＝系統預設；可填 sounddevice 裝置 index 或名稱 |

## 限制／排錯／私隱

- 音訊為記憶體內 mono PCM WAV，正常不寫 temporary file；送到所選 STT 服務。潤飾提示與 Swift 同語意（廣東話／繁體／混合英文），MVP 使用中性語氣，未按 Windows app 自動切換 email／chat 語氣。
- 貼上結果留在 clipboard，方便不接受 SendInput 的控制項手動貼上；**此 MVP 不還原舊 clipboard**。Windows clipboard history／manager 可能保存結果。歷史預設關閉；開啟後是目前使用者 AppData 的普通 JSON，不是加密歷史。
- Windows native HWND focus 可偵測不同控制項／視窗，但瀏覽器、自繪 UI 多個欄位可共用同一 HWND，不能可靠偵測同頁換欄位或游標移動。處理時保持原欄位；不要對密碼或安全欄位錄音。標準 Win32 password edit 會拒絕。
- SendInput 不能證明 app 已接受貼上。管理員／UAC／安全桌面、遠端桌面或特定 app 可能拒絕；先測普通 Notepad，失敗時 Copy last result 手動貼上。
- Hotkey unavailable：更改 `hotkey`，重新啟動；Reload settings 亦會重新註冊。勿與其他 dictation app 使用相同組合。
- Mic error：確認 desktop app 權限、預設 input、其他 app 是否獨佔裝置。查裝置：`.\windows\.venv\Scripts\python.exe -m sounddevice`。USB headset 建議 48 kHz。無錄音裝置的 CI 不代表 PC125 麥克風可用。
- HTTP 401/403：憑證／權限；429：額度；不自動重試。UI 不顯示 HTTP response body 或 tokens。SIWC 登出若遠端撤銷未確認，到 ChatGPT Settings disconnect。
- 關閉 console 或 kill 會結束程式；鎖由 OS 釋放。重新啟動可用同一 DPAPI session。
- 更新：Quit → 在 repo 執行 `git pull --ff-only` → `.\windows\run.bat`；requirements 改動會自動重新安裝。

## 驗證

```powershell
.\windows\.venv\Scripts\python.exe -m unittest discover -s windows/tests -v
```

CI 在 Windows x64／Python 3.12 執行 protocol、native SendInput 結構、hotkey register/unregister、tray/audio/keyring import smoke checks。不錄音、不操作 clipboard、不讀寫真實憑證、不呼叫付費 API。

PC125 手動驗收：Notepad 錄「聽日，唔係，後日三點 send 個 email」→ 檢查潤飾及貼上；再測 Cancel、切換視窗時不貼上、Copy last result、熱鍵衝突，以及 SIWC 登入／重開後 refresh／登出。自動測試不能代替真實 mic、瀏覽器 OAuth、API 帳戶及 focused-control 貼上驗收。
