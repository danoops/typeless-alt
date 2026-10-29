# Typeless Alt — macOS 雙後端語音輸入 MVP

原生 Swift / AppKit menubar app，macOS 13+；Apple Silicon 可直接編譯，無外部 Swift 套件、無需付費 Apple Developer 帳戶。預設 **Control+Option+D**：按一次錄音，再按一次停止 → 轉錄 → 潤飾 → 在原欄位貼上。支援廣東話／繁體中文、English 及混合輸入，移除口頭贅詞、修正自我更正、簡單列表排版；Mail 較正式、Messages 較口語，其餘保留原語氣。

**本機 app，不是離線 AI**：OpenAI 模式將音訊及逐字稿送到 OpenAI；groq-cf 將音訊送到 Groq、逐字稿送到 Cloudflare（或你指定的 Worker）。無自建同步服務；歷史預設關閉。請只輸入願意交予所選服務處理的內容。

## 1. 編譯／啟動

需要 Xcode Command Line Tools（`swift --version`；未安裝可執行 `xcode-select --install`）。

```sh
cd typeless-alt
./run.sh
```

首次啟動會建立 `~/Library/Application Support/typeless-alt/settings.plist`。先用下面其中一種方式設定憑證；沒有憑證仍可啟動及修改設定，但不能錄音。`run.sh` 會 release build、組裝並 ad-hoc 簽署 `build/Typeless Alt.app`，然後直接啟動，保留 shell 環境變數。保持 Terminal 開啟；退出請用 menubar → Quit。勿同時啟動多個實例。

只編譯：`./run.sh --build-only`。使用 Keychain 時，亦可在 Finder 開啟生成的 `.app`，毋須 Terminal；Finder 不會繼承 Terminal 的 `export`。

## 2A. OpenAI（預設）

**ChatGPT Plus 訂閱 ≠ OpenAI API quota。** 需要在 [platform.openai.com](https://platform.openai.com/api-keys) 建立自己的 API key，並在該 OpenAI 帳戶設定 API billing／額度；此程式不使用 ChatGPT 網頁登入或訂閱額度。

在 zsh 安全輸入，避免將 key 寫入 shell history：

```sh
read -rs 'OPENAI_API_KEY?OpenAI API key: '; echo
export OPENAI_API_KEY
./run.sh
```

設定 `backend` 為 `openai`（預設）。STT 預設 `gpt-4o-transcribe`，可改 `whisper-1`；潤飾預設 `gpt-4o-mini`，可改 `gpt-4o`。呼叫真正的 `/v1/audio/transcriptions` 及 `/v1/chat/completions`，無模擬 API 或自動跨供應商 fallback。

## 2B. DIY 免費額度路徑：Groq + Cloudflare Qwen

需要 [Groq API key](https://console.groq.com/keys) 及 Cloudflare Workers AI 帳戶。可利用供應商的免費額度，但**不保證永久免費或不限量**；模型、速率及額度以帳戶當時顯示為準。超限時會顯示錯誤，不會切到 OpenAI 收費路徑。

最簡單：直接呼叫 Cloudflare REST，無需部署 Worker。於 Cloudflare Dashboard 取得 **Account ID**（32 位 hex），建立具該帳戶 **Workers AI Read** 權限的 API token。

```sh
read -rs 'GROQ_API_KEY?Groq API key: '; echo
export GROQ_API_KEY
read -rs 'CF_API_TOKEN?Cloudflare API token: '; echo
export CF_API_TOKEN
export CF_ACCOUNT_ID='你的32位AccountID'
./run.sh
```

menubar → Open settings.plist，將 `backend` 改為 `groq-cf`，儲存後 → Reload settings。亦可在 app 啟動建立設定後，用 Terminal：

```sh
plutil -replace backend -string groq-cf "$HOME/Library/Application Support/typeless-alt/settings.plist"
```

然後在 menubar 按 Reload settings。Groq STT 預設 `whisper-large-v3`，可改為 `whisper-large-v3-turbo`。Cloudflare 預設 `@cf/qwen/qwen3-30b-a3b-fp8`。

### 選用：自己的 Cloudflare Worker

repo 包含受 bearer secret 保護的 `worker/index.js` 及 Wrangler 設定。此路徑讓 Mac 毋須持有 Cloudflare 帳戶 token。

安裝 Node.js/npm 後，在 repo 執行（部署到你登入的 Cloudflare 帳戶）：

```sh
cd worker
npx wrangler login
npx wrangler secret put WORKER_SECRET
# 在提示中貼上自己產生的長隨機密碼；不要使用 CF_API_TOKEN。
npx wrangler deploy
cd ..
```

Mac 設定：

```sh
export CF_WORKER_URL='https://typeless-alt-polish.YOUR-SUBDOMAIN.workers.dev'
read -rs 'CF_WORKER_TOKEN?Worker shared secret: '; echo
export CF_WORKER_TOKEN
# GROQ_API_KEY 仍然需要；backend 仍是 groq-cf。
./run.sh
```

`CF_WORKER_TOKEN` 必須等於 Worker 的 `WORKER_SECRET`。設定 Worker URL 時，優先使用 Worker，不使用 `CF_API_TOKEN`。只將你自己信任的 HTTPS Worker URL 放入設定；逐字稿及 Worker secret 會送到該 URL。Worker 固定使用上述 Qwen 模型，不記錄請求內容；支援兩則 messages 的 POST JSON，回傳 `{"response":"潤飾文字"}`。支援 Cloudflare REST 的 `result.response`／`result.choices` 回應；完整 Qwen `<think>` 區塊會移除，不完整 reasoning 會拒絕貼上。

## 3. Keychain（選用，避免每次 export）

使用 macOS **Keychain Access／鑰匙圈存取** → login keychain → New Password Item／新增密碼項目（generic password）。下列名稱填在 Keychain Item Name／service；Account 可填自己的帳戶名稱，Password 填相應 secret：

| 環境變數 | Keychain service |
| --- | --- |
| `OPENAI_API_KEY` | `typeless-alt` 或 `OpenAI` |
| `GROQ_API_KEY` | `Groq` |
| `CF_API_TOKEN` | `Cloudflare` |
| `CF_WORKER_TOKEN` | `typeless-alt-worker` |

環境變數優先。Keychain 可能要求允許 app 讀取；程式不輸出憑證、不將 secret 存入 plist。Account ID／Worker URL 不是 secret，可分別存於 plist 的 `cloudflareAccountID`／`cloudflareWorkerURL`。環境變數 `CF_ACCOUNT_ID`／`CF_WORKER_URL` 優先。

## 4. 首次授權及實際使用

1. menubar → Grant Accessibility → System Settings → Privacy & Security → Accessibility，允許 **Typeless Alt**。若未列出，按 `+` 選擇 `build/Typeless Alt.app`；需要時退出重開。
2. 在 TextEdit／Mail／Messages 等 app 的可輸入欄位放好游標，按 **⌃⌥D**。第一次會要求 **Microphone**，選 Allow；若拒絕，到 Privacy & Security → Microphone 開啟。
3. menubar 紅色錄音圖示出現後說話，再按 **⌃⌥D** 停止；處理時顯示 `…`。最長錄音 3 分鐘會自動停止；menu → Cancel recording 可取消，取消不呼叫 AI。
4. 等待處理完成，結果以 **⌘V** 插入；選取文字時遵循該 app 的貼上替換行為。**不會按 Enter／寄出訊息**。

處理期間請維持目標 app、欄位及游標位置。若切換 app／欄位，程式會拒絕自動貼上；menubar → **Copy last result** 後自行 ⌘V。同一欄位內移動游標無法可靠偵測，會在貼上當刻的游標位置插入。潤飾失敗時保留原始逐字稿供 Copy last result；不會悄悄貼上未潤飾內容。

Accessibility 允許送出貼上事件，但個別 app、網頁、遠端桌面或安全欄位可能拒絕；無法保證所有 app。已識別的密碼欄位會拒絕。程式檢查原 app／AX focused element 後才發送，**CGEvent 無法證實目標已接受貼上**；若未出現文字，用 Copy last result。剪貼簿會短暫含有結果，約 1.5 秒後在未被其他程式改動時還原；某些 app 若延遲讀取可能需手動貼上，clipboard manager 亦可能保留內容。

## 5. 設定

檔案：`~/Library/Application Support/typeless-alt/settings.plist`。用文字編輯器或 `plutil` 修改，儲存後 menu → Reload settings（錄音／處理時不重載）。缺少新欄位會沿用預設值。

| key | 預設／用途 |
| --- | --- |
| `backend` | `openai` 或 `groq-cf` |
| `keyCode` | `2` = ANSI D（實體鍵位）；`0` = A、`1` = S、`3` = F |
| `modifiers` | `6144` = Control `4096` + Option `2048`；Shift `512`、Command `256` |
| `transcriptionModel` | OpenAI `gpt-4o-transcribe` |
| `polishModel` | OpenAI `gpt-4o-mini` |
| `groqModel` | `whisper-large-v3` |
| `cloudflareModel` | REST 模式 Qwen 模型 ID；Worker 模式在 Worker 程式內固定 |
| `cloudflareAccountID` | 空字串；REST 模式帳戶 ID |
| `cloudflareWorkerURL` | 空字串；有值時改用 Worker |
| `sounds` | `true`；開始／停止提示音，可設 `false` |
| `historyLimit` | `0` 關閉；`1`–`500` 本機保留筆數 |

切回 OpenAI：`plutil -replace backend -string openai "$HOME/Library/Application Support/typeless-alt/settings.plist"`，然後 Reload settings。不需重新編譯。快捷鍵衝突會提示，修改後重載即可。

## 6. 儲存／排錯／驗證

- 音訊暫存在 macOS temporary directory，完成、失敗或取消後刪除；強制 kill／崩潰可能留下 `typeless-alt-*.m4a`，可手動清理。
- 最後一次結果在記憶體保留至退出；啟用歷史才會將時間及潤飾文字寫到 support folder 的 `history.json`（權限 600），沒有雲端同步。將 historyLimit 改成 0 會停止新增，**不會刪除既有檔案**；可從 Open local data folder 手動刪除。
- HTTP 401：檢查該後端 secret／token；403：檢查帳戶、權限及模型存取；429：檢查免費額度、rate limit 或 API billing。請求逾時約 120 秒；不自動重試以避免重複收費。
- 重新編譯 ad-hoc app 後 macOS 可能要求重新授權 Accessibility／Keychain。若權限顯示開啟仍失效，在設定移除舊 app，再加入同一路徑的 app。
- 麥克風取系統預設輸入裝置，可在 System Settings → Sound → Input 切換。提示音可被麥克風收錄，建議用耳機或關閉 sounds。
- 沒聲音、太短或環境嘈雜可令 STT 產生錯誤；潤飾亦可能改錯內容，發送前請檢查人名、數字及意圖。

本機測試／編譯：

```sh
swift test
node worker/test.mjs  # 選用：需要 Node.js，僅本機 fixture 測試
./run.sh --build-only
```

自動測試涵蓋舊設定遷移、後端值驗證、Cloudflare REST／Worker 回應及 Qwen reasoning 處理、語言／app 語氣提示。這些測試不發送 API 請求。實際端到端驗收：為兩個後端各自在 TextEdit 說「聽日，唔係，後日三點 send 個 email」，確認最終意思、繁體／英文、貼上；再測切換欄位後保留結果、取消錄音及 sounds=false。

本 repo 已在此 Apple Silicon Mac 完成 release 編譯。沒有使用你的付費 API、錄音或代授權系統權限；真實麥克風 → API → 目標 app 貼上仍須按以上步驟本機驗收。

API 參考：[OpenAI audio](https://developers.openai.com/api/reference/resources/audio/subresources/transcriptions/methods/create)、[OpenAI Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create)、[Groq STT](https://console.groq.com/docs/speech-to-text)、[Cloudflare Qwen](https://developers.cloudflare.com/workers-ai/models/qwen3-30b-a3b-fp8/)。模型供應及免費額度可能變動，可透過設定更新。
