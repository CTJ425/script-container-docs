# RHEL/Rocky VM 範本封裝與開機初次設定套件 (RHEL-Family-Temp)

本專案將 **虛擬機安全封裝 (Sealing)** 與 **開機首次登入引導設定 (First-boot Setup)** 整合為一體化解決方案。

透過此套件，系統管理員可以使用單一指令（一鍵部署）完成母版虛擬機（Master VM）的環境清理與設定裝載。當複製出來的新虛擬機（VM Template Clones）首次開機並由 `root` 登入時，系統會自動啟動互動式精靈，引導使用者完成主機名稱與網路卡 (Static IPv4) 的配置，打造如同商用設備般的「開箱即用 (Out-of-Box Experience)」體驗。

---

## 錄 (Table of Contents)

1. [編輯與更新紀錄](#編輯與更新紀錄)
2. [適用作業系統](#適用作業系統)
3. [專案檔案結構](#專案檔案結構)
4. [一鍵部署與使用方式](#一鍵部署與使用方式)
5. [開機引導設定體驗](#開機引導設定體驗)
6. [代碼審查與邏輯優化紀錄 (Code Review & Audit)](#代碼審查與邏輯優化紀錄-code-review--audit)
7. [授權條款 (License)](#授權條款-license)

---

## 編輯與更新紀錄

| 編輯日期 | 編輯人員 | 編輯內容 |
| :--- | :--- | :--- |
| 2026/07/07 | Ivan Chen / Antigravity | 1. 合併 `Inital-setup` 與 `Seal_RHEL_VM` 專案。<br>2. 新增整合式一鍵封裝腳本 `seal-rhel-template.sh`。<br>3. 引入輸入驗證迴圈 (IP, 遮罩, Gateway, DNS)。<br>4. 新增 dotted-decimal 遮罩自動轉換 CIDR 邏輯。<br>5. 修正 NetworkManager 虛擬機複製後 UUID 重疊問題。<br>6. 強化 `/etc/resolv.conf` 軟連結處理，避免破壞系統 DNS 整合。<br>7. 於 TTY 登入觸發點加入 `[ -t 0 ]` 判斷，避免自動化/SFTP/Ansible 掛死。 |

---

## 適用作業系統

* **Red Hat Enterprise Linux (RHEL)** 8.x / 9.x / 10.x
* **Rocky Linux** 8.x / 9.x / 10.x
* **AlmaLinux / CentOS Stream** 等相容系統

> [!IMPORTANT]
> 本套件高度依賴 `NetworkManager` 及 `nmcli` 工具。執行封裝與初始化前，請確保系統已啟用 NetworkManager 服務。

---

## 專案檔案結構

```text
RHEL-Family-Temp/
├── initial-setup.sh      # 首次開機引導設定精靈 (會被安裝至 /usr/local/bin/)
├── 99-firstboot.sh       # 系統設定檔觸發器 (會被安裝至 /etc/profile.d/)
├── seal-rhel-template.sh # 整合式封裝主腳本 (一鍵清理並裝載以上設定檔)
├── README.md             # 本說明文件
└── LICENSE               # MIT 授權條款
```

---

## 一鍵部署與使用方式

您無須提前下載任何檔案，只需在預備製作為範本的母版虛擬機 (Master VM) 上，以 `root` 權限執行 `curl` 指令即可。

### 1. 預覽清理動作 (Dry-run)

在不對系統進行任何實際修改的情況下，檢視將執行的封裝與清理項目：
```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/RHEL-Family-Temp/seal-rhel-template.sh | sudo bash -s -- --dry-run
```

### 2. 互動式執行 (預設)

執行封裝，並於開始前提示管理員進行確認：
```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/RHEL-Family-Temp/seal-rhel-template.sh | sudo bash
```

### 3. 自動封裝並自動關機 (推薦)

略過確認提示，在完成封裝與初始化部署後，自動關閉虛擬機電源。**此時即可直接將該虛擬機轉換為 VM 範本 (Template)**：
```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/RHEL-Family-Temp/seal-rhel-template.sh | sudo bash -s -- --yes --poweroff
```

### 參數說明

| 參數 | 說明 |
| :--- | :--- |
| `--dry-run` | 僅顯示會執行的動作，不實際修改系統。 |
| `--yes` | 略過互動確認提示，適合自動化封裝流程。 |
| `--poweroff` | 封裝清理完畢後，自動執行 `systemctl poweroff` 關機。 |
| `-h`, `--help` | 顯示腳本參數說明。 |

---

## 開機引導設定體驗

當新虛擬機從範本部署完成並開機後，管理者使用 `root` 帳號進行本地主機 Console 登入時，系統會自動清除螢幕並顯示如下引導畫面：

```text
==========================================================
 Welcome to Red Hat Enterprise Linux 9 Initial Setup
 This script will run only once on the first root login.
 ==========================================================

--- Step 1: Select Network Interface ---
Multiple ethernet devices found. Please choose one:
1) ens192
2) ens224
#? 1
You selected: ens192

--- Step 2: Configure Network Settings for 'ens192' ---
Change [192.168.10.50] ipv4: 192.168.1.120
Change [24] netmask (CIDR prefix, e.g. 24, or subnet mask): 255.255.255.0
Change [192.168.10.1] gateway (press Enter if none): 192.168.1.1
Change [192.168.10.254] dns (space or comma separated, or press Enter if none): 8.8.8.8 8.8.4.4

--- Step 3: Configure Hostname ---
Change [localhost.localdomain] hostname: web-prod-01

===== Start change nic setting =====
Connection 'ens192' (xxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx) successfully modified.
Connection successfully activated (D-Bus active path: /org/freedesktop/NetworkManager/ActiveConnection/1)
===== Change nic setting done =====

===== Start change hostname =====
Hostname has been set to: web-prod-01
===== Change hostname done =====

Setup is complete. Creating flag file to prevent this script from running again.
Reboot now to apply all changes? (y/n): y
```

重開機後，旗標檔案 `/etc/firstboot_completed` 已觸發，後續不論是 Console 還是 SSH 登入，都將直接進入標準的 Shell。

---

## 代碼審查與邏輯優化紀錄 (Code Review & Audit)

在合併兩個專案的過程中，我們對原始腳本進行了深度的 Code Review，修復了數個可能導致生產環境故障的邏輯漏洞，並在 `seal-rhel-template.sh` 與 `initial-setup.sh` 中進行了以下優化：

### 1. 網路遮罩 (Netmask) 容錯與自動轉換 (新增於 `initial-setup.sh`)
* **原邏輯問題**：原 `initial-setup.sh` 僅接受 CIDR 數值（如 `24`）。如果使用者輸入傳統點分十進制遮罩（如 `255.255.255.0`），腳本會直接套用至 `nmcli`，導致 nmcli 配置失敗並使設定流程崩潰中斷。
* **優化方案**：新增 `mask_to_cidr` 轉換函式。當使用者輸入 `255.255.255.0` 時，腳本會將其自動轉換為二進制並計算 `1` 的數量，轉化為 `24` 傳遞給 NetworkManager。此設計同時支援傳統掩碼與 CIDR。

### 2. 高強健性輸入驗證 (Validation Loops) (新增於 `initial-setup.sh`)
* **原邏輯問題**：原腳本沒有對使用者的輸入進行防呆。若輸入了錯誤格式的 IP 或 DNS（例如少打一個點、或誤輸入字母），腳本在套用 `nmcli` 時會報錯中斷，並將未配置完全的網路狀態殘留。
* **優化方案**：引入 IP 與 DNS 格式正則驗證。使用 `while true` 迴圈引導輸入，若輸入格式不符將印出明確的錯誤訊息並要求重新輸入，直到格式正確為止，避免中途崩潰。

### 3. profile.d 登入掛死防護與非互動模式支援 (修正於 `99-firstboot.sh`)
* **原邏輯問題**：原觸發器僅過濾 `[ -z "$SSH_TTY" ]`，意即「非 SSH 登入就觸發」。然而，當自動化維運工具（如 Ansible、SFTP、SCP、無 TTY 的自動化指令）透過非 SSH 連線（如本機 cron、systemd service、或特殊自動化 agent）以 root 執行指令時，因沒有互動式終端介面，執行到 profile 時會因為 `read` 指令等待輸入而永久掛死。
* **優化方案**：於觸發條件中額外加入 `[ -t 0 ]` 檢測，確保 **標準輸入為 TTY 終端** 時才觸發設定精靈。這完全解決了 Ansible 或備份排程腳本在首次登入時被卡死的問題。

### 4. 解決虛擬機複製後 UUID 重疊問題 (修正於 `seal-rhel-template.sh`)
* **原邏輯問題**：原 `seal-rhel-template.sh` 會清除 `/etc/NetworkManager/system-connections/*.nmconnection` 檔案中的 `uuid`。但在 RHEL 9/10 中，如果 connection 檔案中完全沒有 uuid 欄位，NetworkManager 有時會拒絕載入該設定檔，或將其視為無效。
* **優化方案**：在封裝時，若系統上存在 `uuidgen` 指令，腳本會自動為各個連線設定檔生成一組全新的隨機 UUID 並寫回，徹底避免複製品 UUID 衝突，同時符合 NetworkManager 的檔案規範。

### 5. 安全處理 `/etc/resolv.conf` 軟連結 (修正於 `seal-rhel-template.sh`)
* **原邏輯問題**：原封裝腳本在遇到 `/etc/resolv.conf` 是 symbolic link 時，會直接將其刪除並重新 `touch` 一個空白常規檔案。這會永久切斷 NetworkManager 或 systemd-resolved 對 DNS 解析檔案的軟連結管理，導致新 VM 開機後無法自動寫入 DNS 伺服器。
* **優化方案**：在現代 RHEL (9/10) 中，DNS 軟連結多指向 `/run` 暫存目錄（如 `/run/NetworkManager/resolv.conf`），這類暫存檔在重開機後會自動消亡重構。因此，封裝腳本優化為：**若 `/etc/resolv.conf` 為 symbolic link 則不予以破壞刪除，維持系統預設的動態 DNS 機制**。

### 6. 深入清理系統暫存與日誌 (新增於 `seal-rhel-template.sh`)
* **優化方案**：除了原有的機器識別資料清理外，新版封裝腳本額外加入了暫存清理與系統日誌縮減：
  - 清理 `/tmp` 及 `/var/tmp` 下的所有暫存檔案。
  - 清除 `dnf` 套件管理器快取 (`dnf clean all`)。
  - 縮減並排空 `/var/log` 下的系統文字日誌，並對 `journalctl` 進行 vacuum 縮小體積，使封裝後的虛擬機範本磁碟映像檔更加乾淨，佔用空間更小。

### 7. 主機名稱與 `/etc/hosts` 同步更新 (修正於 `initial-setup.sh`)
* **原邏輯問題**：修改新主機名稱後，沒有在 `/etc/hosts` 中同步加入與 `127.0.0.1` 的對應，導致類似 `sudo` 的系統工具在執行時因本機解析逾時而出現 5~10 秒的卡頓。
* **優化方案**：在修改主機名稱完成後，自動在 `/etc/hosts` 的 `127.0.0.1` 列追加新主機名稱。

### 8. 精準清除 `/etc/hosts` 本機名稱 (修正於 `seal-rhel-template.sh`)
* **原邏輯問題**：原封裝腳本利用 `cat >` 直接覆寫 `/etc/hosts` 為預設內容，這會將管理員先前客製化的本機解析規則全部抹除。
* **優化方案**：改用 `sed` 精準匹配並僅從 `/etc/hosts` 中移除目前的主機名稱，完全保留管理員的其他客製化解析條目。

## 💡 額外安全性注意事項 (Sealing Security Caveats)

### 📌 Shell 歷史紀錄殘留防護
* **問題說明**：封裝腳本 `seal-rhel-template.sh` 雖會清理 `/root/.bash_history` 等歷史檔案，但由於當前管理員執行的 SSH 或本地互動式 Shell 終端在登出/關機時，作業系統會將該次連線期間的所有歷史指令寫入歷史檔案，造成封裝完的範本開機後仍殘留封裝前的操作軌跡。
* **建議做法**：在執行 `seal-rhel-template.sh` 之後，建議在當前的互動式 Shell 中手動執行：
  ```bash
  history -c && history -w && exit
  ```
  或者強行結束當前 Shell 的父程序，使其在不觸發寫回歷史檔的情況下離線：
  ```bash
  kill -9 $PPID
  ```
  以確保登出時不會將當前終端的指令歷史寫回磁碟，維持範本的最高乾淨度與密鑰安全性。

---

## 授權條款 (License)

本專案基於 **MIT License** 進行授權。
