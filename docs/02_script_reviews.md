# 各腳本詳細代碼審查與漏洞診斷報告 (Detailed Script Review & Audit)

> **文件版本**：1.0  
> **審查目標**：逐一分析專案中所有 Bash 腳本與 Docker 設定檔之邏輯缺陷、資安漏洞及邊緣狀況。

---

## 1. `Inital-setup/initial-setup.sh` (舊版開機設定腳本)

### 📋 腳本功能說明
此腳本旨在當 RHEL 9 VM 首次開機且 Root 登入時，透過互動式問答讓管理員設定網卡 (Static IPv4 / Netmask / Gateway / DNS) 與系統 Hostname，完成後建立 `/etc/firstboot_completed` 旗標檔防止重複執行。

### 🔍 缺陷與漏洞診斷

#### 缺陷 1.1：完全缺乏輸入格式驗證 (Severity: 🔴 High)
* **位置**：第 118 - 153 行
* **原始程式碼**：
  ```bash
  read -r -e -p "Change [$ch_ipv4] ipv4: " ipv4
  read -r -e -p "Change [$ch_netmask] netmask (CIDR): " netmask
  ```
* **問題說明**：程式未對使用者輸入的 IP、網段遮罩、網關與 DNS 進行任何格式與合理性檢查。若管理員輸入非法格式（例如 `192.168.1.300` 或字串 `abc`），程式會直接帶入 `nmcli` 指令，導致 NetworkManager 設定壞軌或網卡無法啟動。

#### 缺陷 1.2：`nmcli` 位置參數錯位 Bug (Severity: 🔴 High)
* **位置**：第 156 - 162 行
* **原始程式碼**：
  ```bash
  run_or_fail nmcli connection modify "$CON_NAME" \
              ipv4.method manual \
              ipv4.addresses "$ipv4/$netmask" \
              ipv4.gateway "$gw4" \
              ipv4.dns "$dns4" \
              ipv4.ignore-auto-dns yes \
              autoconnect yes
  ```
* **問題說明**：當管理員留空 Gateway (`$gw4=""`) 或未設定 DNS 時，`ipv4.gateway "$gw4"` 會展開為 `ipv4.gateway ""`，甚至在無引號變數下會將後續的 `ipv4.dns` 當作 `ipv4.gateway` 的參數值，造成整條 `nmcli` 命令參數對位錯誤並宣告失敗。

#### 缺陷 1.3：缺乏併發執行鎖 (Multi-TTY Race Condition) (Severity: 🟡 Medium)
* **位置**：第 24 - 26 行
* **問題說明**：僅以 `/etc/firstboot_completed` 檔案存在與否作為判斷。若管理員在開機時同時開起了多個本地 TTY Console 登入 root，多個 `initial-setup.sh` 程序將會同時觸發並競爭讀寫 NetworkManager，造成設定覆蓋衝突。

#### 缺陷 1.4：未同步更新 `/etc/hosts` 導致 Sudo 延遲 (Severity: 🟡 Medium)
* **位置**：第 169 - 171 行
* **問題說明**：使用 `hostnamectl set-hostname` 設定新主機名稱後，未同步將新名稱寫入 `/etc/hosts` 的 `127.0.0.1` 條目中。這會導致系統在執行 `sudo` 或本機名稱解析時發生長達數十秒的 DNS 查詢逾時延遲。

#### 缺陷 1.5：單一網卡環境重複詢問 (Severity: 🟢 Low)
* **位置**：第 67 - 73 行
* **問題說明**：在只有一張網卡的標準 VM 環境中，腳本依然跳出提示要求使用者選擇網卡，增加了無謂的手動按鍵需求與手誤打錯字的機率。

---

## 2. `Inital-setup/99-firstboot.sh` & `RHEL-Family-Temp/99-firstboot.sh`

### 📋 腳本功能說明
放置於 `/etc/profile.d/` 下的 Shell 啟動腳本，在 root 登入時檢查旗標檔，若尚未設定則自動呼叫 `/usr/local/bin/initial-setup.sh`。

### 🔍 缺陷與漏洞診斷

#### 缺陷 2.1：`SSH_TTY` 檢查阻擋 SSH 登入自動觸發 (Severity: 🟡 Medium)
* **位置**：第 3 行
* **原始程式碼**：
  ```bash
  if [ -n "$BASH_VERSION" ] && [ -z "$SSH_TTY" ] && [ "$(id -u)" -eq 0 ]; then
  ```
* **問題說明**：`[ -z "$SSH_TTY" ]` 條件強制限定只有在實體 Console / TTY 登入時才觸發。在雲端環境或無頭伺服器 (Headless VM) 中，管理員透過 SSH 首次登入 root 時，將完全不會觸發初始化設定。

#### 缺陷 2.2：路徑硬編碼與執行權限缺乏檢查 (Severity: 🟢 Low)
* **位置**：第 5 行
* **原始程式碼**：
  ```bash
  /usr/local/bin/initial-setup.sh
  ```
* **問題說明**：硬編碼路徑；若目標腳本未賦予 `+x` 執行權限，Profile 載入時會拋出 Shell 語法錯誤警報。

---

## 3. `Seal_RHEL_VM/seal-rhel-template.sh` (VM 封裝工具)

### 📋 腳本功能說明
將已經設定好的 RHEL / Rocky Linux 虛擬機進行清理 (Reset / Clean)，刪除 MAC 地址、UUID、SSH Host Key、Machine-ID、Shell History、Subscription 等，以便將該 VM 轉為金像獎範本 (Template)。

### 🔍 缺陷與漏洞診斷

#### 缺陷 3.1：覆寫破壞 `/etc/hosts` 自訂解析 (Severity: 🔴 High)
* **位置**：第 158 - 161 行
* **原始程式碼**：
  ```bash
  run_shell_required "cat > /etc/hosts <<'EOF'
  127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
  ::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
  EOF"
  ```
* **問題說明**：採用重定向 `cat > /etc/hosts` 直接抹除並覆寫整個 `/etc/hosts` 檔案。如果管理員在範本中預先設定了內網 DNS 或內部服務解析 (如自建 Yum/AppStream 源)，將會被全數強制清空。

#### 缺陷 3.2：Machine-ID 寫入非法字串 (Severity: 🔴 High)
* **位置**：第 188, 191 行
* **原始程式碼**：
  ```bash
  run_shell_required "printf 'uninitialized\n' > /etc/machine-id"
  ```
* **問題說明**：在 systemd 規範中，`/etc/machine-id` 應為 32 字元的十六進位隨機數，或是完全空白檔案（或刪除讓 systemd 開機自動產生）。寫入 `uninitialized\n` 會導致部分 systemd 服務將字串 `"uninitialized"` 當作有效的 machine-id，造成複製出來的所有 VM 機號完全相同，產生衝突。

#### 3.3：OS 偵測遺漏 AlmaLinux (Severity: 🟡 Medium)
* **位置**：第 92 - 95 行
* **原始程式碼**：
  ```bash
  case " $OS_ID $OS_ID_LIKE " in
    *" rhel "*|*" rocky "*|*" centos "*|*" fedora "*) ;;
    *) die "Unsupported OS family: $OS_NAME..." ;;
  esac
  ```
* **問題說明**：未包含 `almalinux`。在 AlmaLinux 8/9 系統上執行此腳本會直接觸發 fatal die 退出，無法完成封裝。

#### 缺陷 3.4：Shell 歷史紀錄清理命令冗餘 (Severity: 🟢 Low)
* **位置**：第 224 行
* **原始程式碼**：
  ```bash
  optional_run env HISTFILE="$history_file" bash -c 'history -c; history -w'
  ```
* **問題說明**：在非互動式 Shell 中，Bash 預設關閉 History 機制，執行 `history -c` 無實質意義，且隨後已透過 `rm -f "$history_file"` 刪除檔案，該行屬無用代碼。

---

## 4. `RHEL-Family-Temp/initial-setup.sh` (改良版開機設定腳本)

### 📋 腳本功能說明
針對舊版進行修正的版本，引進了 `validate_ip`, `mask_to_cidr`, `validate_dns`, `validate_hostname` 驗證函式，並改用 Bash 陣列處理 `nmcli` 參數。

### 🔍 殘存缺陷診斷

#### 缺陷 4.1：`validate_dns` 未引號展開 Globbing 安全漏洞 (Severity: 🟢 Low)
* **位置**：第 107 行
* **原始程式碼**：
  ```bash
  for dns_server in ${dns//,/ }; do
  ```
* **問題說明**：未引號的單詞展開在含有 `*` 或 `?` 時會觸發路徑檔名展開 (Globbing)。雖然腳本在第 102-103 行加入了 `local -; set -f` 關閉屏障，但還原與邏輯可進一步優化。

#### 缺陷 4.2：DNS 字串前後空格未清空 (Severity: 🟢 Low)
* **位置**：第 269 行
* **原始程式碼**：
  ```bash
  dns4=$(echo "$dns4" | tr ',' ' ' | tr -s ' ')
  ```
* **問題說明**：若使用者輸入首尾帶有空白，轉換後空格未做 trim 處理，傳給 NetworkManager 時可能引發格式警告。

#### 缺陷 4.3：`/etc/hosts` 主機名稱重複追加 (Severity: 🟢 Low)
* **位置**：第 322 - 324 行
* **原始程式碼**：
  ```bash
  if ! grep -q " $hostname_edit" /etc/hosts; then
      sed -i "/^127.0.0.1/s/$/ $hostname_edit/" /etc/hosts
  fi
  ```
* **問題說明**：僅以子字串 `grep -q " $hostname_edit"` 匹配。若主機名稱被多次修改或包含相似字首，會導致 `/etc/hosts` 累積多餘的無用字串。

---

## 5. `pve_link_iso/pve_link_iso.sh` & `pve_link_iso_old.sh` (Proxmox ISO 同步腳本)

### 📋 腳本功能說明
掃描 `$SOURCE_DIR` 中的所有 ISO 檔案，並在 Proxmox VE 的儲存目錄 `$TARGET_DIR` 建立 Symlink。

### 🔍 缺陷與漏洞診斷

#### 缺陷 5.1：`pve_link_iso_old.sh` 管道子 Shell 變數作用域死結 (Severity: 🔴 High)
* **位置**：`pve_link_iso_old.sh` 第 39 - 48 行
* **原始程式碼**：
  ```bash
  find "$SOURCE_DIR" ... | while IFS= read -r -d $'\0' iso_file; do
      ...
      ((COUNT++))
  done
  echo "總共建立了 $COUNT 個新的符號連結。"
  ```
* **問題說明**：在 Bash 中，透過管道 `|` 連接的 `while` 迴圈會在**獨立的子 Shell (Subshell)** 中執行。在子 Shell 內修改的 `COUNT` 變數在迴圈結束後會隨子 Shell 一起銷毀。因此主 Shell 印出的 `$COUNT` 永遠是 `0`！

#### 缺陷 5.2：無效/斷開的符號連結 (Dangling Symlinks) 跳過 Bug (Severity: 🔴 High)
* **位置**：`pve_link_iso.sh` 第 40 行
* **原始程式碼**：
  ```bash
  if [ ! -e "$target_file" ]; then
  ```
* **問題說明**：在 Bash 測試運算子中，`[ -e "$target_file" ]` 對於**已斷開的軟連結 (Dangling Symlink)** 會回傳 `false`（因為 `-e` 會追蹤連結目標是否存在）。因此 `[ ! -e "$target_file" ]` 對斷開的連結回傳 `true`，但隨後執行 `ln -s` 會因為檔案路徑 (Symlink 本身) 已存在而拋出 `File exists` 錯誤並失敗！正解應改用 `[ ! -L "$target_file" ] && [ ! -e "$target_file" ]` 或 `[ -h "$target_file" ]`。

#### 缺陷 5.3：多層目錄同名 ISO 覆蓋與忽略 (Severity: 🟡 Medium)
* **位置**：`pve_link_iso.sh` 第 37 - 38 行
* **問題說明**：如果來源目錄下不同子目錄存在相同名稱的 ISO (例如 `ISO/CentOS/installer.iso` 與 `ISO/Ubuntu/installer.iso`)，`target_file="${TARGET_DIR}/${filename}"` 會發生檔名衝突，第二個 ISO 會被直接跳過且無法建立連結。

---

## 6. `k8s_env_init/k8s_env_initialization.sh` (Kubernetes 前置初始化腳本)

### 📋 腳本功能說明
準備 Kubernetes 部署所需的系統環境，包含停用 Firewall、關閉 Swap、停用/放行 SELinux、載入 `overlay` / `br_netfilter` 核心模組，以及設定 `net.bridge.bridge-nf-call-iptables` 等 sysctl 核心參數，並具備自我驗證能力。

### 🔍 診斷評估 (Severity: 🟢 Low)
* **優點**：結構非常嚴謹，具備完善的 OS 檢測 (包含 AlmaLinux, Rocky, Ubuntu, Debian)、函數化設計、詳細的驗證機制 (`verify_setup`) 以及非互動 Shell 檢測 (`[ -t 0 ]`)。
* **微小優化點**：
  1. **SELinux 關閉方式**：腳本透過 `grubby --update-kernel ALL --args selinux=0` 強制在核心參數加入 `selinux=0`。在 RHEL 9 中，官方建議改用 `/etc/selinux/config` 設為 `permissive` 或 `disabled`，以避免核心硬關閉導致部分容器套件上下文載入異常。
  2. **fstab 備份覆寫**：`sed -r -i.bak` 在多次重複執行時，會將最初的備份檔覆寫為已修改過的版本。

---

## 7. `Container/ollama/docker-compose.yml` (容器部署檔)

### 📋 內容與功能說明
使用 Docker Compose 部署 Ollama 大語言模型引擎與 Open-WebUI 前端介面。

### 🔍 診斷評估 (Severity: 🟡 Medium)

#### 缺陷 7.1：硬性 GPU 資源綁定 (Severity: 🟡 Medium)
* **位置**：第 10 - 16 行
* **問題說明**：配置中明確要求 NVIDIA GPU Driver (`driver: nvidia`, `count: 1`)。若在無獨立顯卡或未安裝 `nvidia-container-toolkit` 的純 CPU 伺服器上執行 `docker compose up -d`，容器將直接拋出錯誤並無法啟動。

#### 缺陷 7.2：使用浮動映像檔標籤 (Floating Tags) (Severity: 🟢 Low)
* **位置**：第 5, 21 行 (`ollama/ollama:latest`, `open-webui:main`)
* **問題說明**：使用 `latest` 與 `main` 標籤會導致每次重啟或重新拉取時取得未知的版本更新，可能引發版次不相容或破壞性變更。建議鎖定具體版本號（如 `ollama/ollama:0.5.7`）。
