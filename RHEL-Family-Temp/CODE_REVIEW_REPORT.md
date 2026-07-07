# RHEL/Rocky VM 範本封裝與開機設定腳本——第四輪代碼審查報告 (Code Review & Audit Report)

本報告針對 [RHEL-Family-Temp](file:///mnt/c/Users/user/Documents/Configuration/script-container-docs/RHEL-Family-Temp/) 專案目錄下的現有最新版本指令碼程式進行安全性與穩定性的純代碼邏輯審查（Code Review）。
應管理員要求，**本報告僅指出程式中的邏輯問題與提供修改建議，未對任何原始程式碼進行實體修改。**

---

## 🛠️ 第一階段：已修正之代碼漏洞確認 (Status: Resolved)

經過比對，專案目前最新版本的程式碼中已成功套用了前幾輪審查的優化，解決了以下關鍵問題：

1. **遮罩二進位轉換修正**：`mask_to_cidr` 函式已成功改用純 Bash 算術迴圈，免除了對 `bc` 工具的依賴並修正了進位轉換 Bug。
2. **IP 驗證防前導零**：`validate_ip` 正規表達式已更新為 `^(0|[1-9][0-9]*)$`，阻擋了會導致 Bash 算術運算產生八進位語法錯誤的前導零輸入。
3. **hosts 檔主機名稱同步**：變更 hostname 後，已同步於 `/etc/hosts` 中將新名稱追加至 `127.0.0.1` 行尾，消除了 `sudo` 執行卡頓延遲的問題。
4. **hosts 檔自訂規則保護**：封裝腳本 `seal-rhel-template.sh` 已將抹除式的覆寫機制改為精準使用 `sed` 僅刪除目前主機名稱，成功保留了管理員原配置的自訂解析規則。
5. **主機名稱格式防呆**：新增了 `validate_hostname` 驗證函式，使 hostname 修改流程更為健壯。

---

## 🔍 第二階段：最新代碼審查發現與優化建議 (Status: Open)

在目前的最新版代碼中，我們進一步發現了以下 5 個程式編寫或邏輯設計上的優化空間：

### 1. 單一網卡環境下的互動提示優化（建議等級：🟢 低 - 體驗優化）

* **存在於**：`initial-setup.sh` (第 155-160 行)。
* **原程式碼**：
  ```bash
  elif [ "$device_count" -eq 1 ]; then
      default_device=${devices[0]}
      read -r -e -p "Select device to edit [$default_device]: " ch_device
      if [ -z "$ch_device" ]; then
          ch_device="$default_device"
      fi
  ```
* **問題說明**：
  如果系統中只有一張網卡（這是絕大多數虛擬機範本的標準狀態），程式依然會彈出 `Select device to edit` 提示要求使用者輸入。這增加了一次手動操作，且若使用者不小心打錯字（例如手動輸入了不存在的網卡名稱），會導致後續建立 nmcli 設定檔或啟用網卡時失敗。
* **修復建議**：
  在只有單一網卡時，直接自動選定該網卡並印出資訊即可，免除手動輸入與打錯字的風險：
  ```bash
  elif [ "$device_count" -eq 1 ]; then
      ch_device=${devices[0]}
      echo "Only one ethernet device found. Auto-selected '$ch_device'."
  ```

---

### 2. 未引號變數展開導致路徑通配展開 (Globbing)（建議等級：🟢 低 - 安全規範）

* **存在於**：`initial-setup.sh` (第 102 行) 與 `seal-rhel-template.sh` 中的 `validate_dns` 函式。
* **原程式碼**：
  ```bash
  for dns_server in ${dns//,/ }; do
  ```
* **問題說明**：
  在此 `for` 迴圈中，變數 `${dns//,/ }` 採用了未加引號的單詞展開。如果使用者輸入含有通配符（如 `*` 或 `?`），Bash 會將其視為路徑展開指令，嘗試去搜尋並替換為當前目錄下的檔案名稱列表。
* **修復建議**：
  在執行單詞分割前使用 `set -f` 暫時關閉 Globbing，並在結束後以 `set +f` 還原：
  ```bash
  local -f
  set -f
  for dns_server in ${dns//,/ }; do
      # 驗證邏輯...
  done
  set +f
  ```

---

### 3. DNS 格式化前後空格清理未落實（建議等級：🟢 低 - 健壯性）

* **存在於**：`initial-setup.sh` (第 269 行)。
* **原程式碼**：
  ```bash
  dns4=$(echo "$dns4" | tr ',' ' ' | tr -s ' ')
  ```
* **問題說明**：
  原程式在轉換空格並壓縮連續空格後，並未進行頭尾去空格的動作。若使用者在輸入時的首尾留有空白字元，該空白會被原封不動傳入 `NM_ARGS` 並作為 `ipv4.dns` 的一部分交給 `nmcli`，這可能在特定的 NetworkManager 版本中引起參數語法警告。
* **修復建議**：
  轉換後，使用 Bash 內建切片將前後可能殘留的空格剔除：
  ```bash
  dns4=$(echo "$dns4" | tr ',' ' ' | tr -s ' ')
  dns4=${dns4# }
  dns4=${dns4% }
  ```

---

### 4. 防範多終端登入之併發衝突（建議等級：🟡 中 - 系統穩定性）

* **存在於**：`initial-setup.sh` 的啟動引導設計。
* **問題說明**：
  當新複製的 VM 開機後，系統會防守 root 的本地登入。但若管理員同時開啟了多個本地 TTY 終端登入 root，由於此時限制執行的 flag 檔案 `/etc/firstboot_completed` 尚未產生，**這多個終端將會同時、並發地執行 `initial-setup.sh` 精靈**。這會導致兩邊輸入的設定在寫入 NetworkManager 時發生競爭與衝突。
* **修復建議**：
  在 `initial-setup.sh` 啟動開頭建立一個臨時的 Lock 目錄（或利用 `mkdir` / `flock`），確保同一時間只有一個終端能執行設定精靈，其餘的並發執行則靜態等待或直接退出：
  ```bash
  LOCK_DIR="/run/initial-setup.lock"
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
      echo "Another instance of initial-setup is already running. Exiting."
      exit 0
  fi
  trap 'rm -rf "$LOCK_DIR"' EXIT
  ```

---

### 5. 歷史紀錄清理命令冗餘（建議等級：🟢 低 - 代碼簡化）

* **存在於**：`seal-rhel-template.sh` (第 682 行前後)。
* **原程式碼**：
  ```bash
  optional_run env HISTFILE="$history_file" bash -c 'history -c; history -w'
  ```
* **問題說明**：
  在以非互動方式執行腳本時，Bash 預設不啟用歷史紀錄追蹤。因此在 `bash -c` 子 Shell 中叫用 `history` 無任何效果，且底下已配有 `rm -f "$history_file"` 進行實體刪除，該行指令屬冗餘代碼。
* **修復建議**：
  直接移除此行以簡化封裝清理流程。

---

## 🛠️ 2026-07-07 審查結論 (Status: Pending Code Revert/Review Only)

應管理員要求，**本專案目錄下的所有原始程式碼檔案均維持原封不動狀態（未進行任何實體修改）**。本報告中指出的各項診斷問題僅供未來修改參考。

報告完畢。
*(註：本目錄下的程式檔已維持原封不動狀態。)*
