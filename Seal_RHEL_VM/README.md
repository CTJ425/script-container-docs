# RHEL8/RHEL9/RHEL10 VM Template Seal Script

# 編輯紀錄

| 編輯日期 | 編輯人員 | 編輯內容 |
| --- | --- | --- |
| 2026/06/25 | Ivan Chen | 初版 |
| 2026/06/25 | Ivan Chen | 強化 OS 判斷與必要清理步驟錯誤處理 |
| 2026/06/25 | Ivan Chen | 補強 NetworkManager 介面名稱綁定清理 |
| 2026/06/25 | Ivan Chen | 補充 RHEL/Rocky 10.x 支援與 Satellite 套件偵測修正 |
| 2026/07/07 | Ivan Chen | 補充 curl 直接執行方式 |
| 2026/07/07 | Ivan Chen | 調整 hosts 清理邏輯，保留標準 loopback 項目 |
| 2026/07/07 | Ivan Chen | 強化互動式確認、resolv.conf 與 machine-id 清理邏輯 |

# 適用版本

- Red Hat Enterprise Linux 8.x
- Red Hat Enterprise Linux 9.x
- Red Hat Enterprise Linux 10.x
- Rocky Linux 8.x
- Rocky Linux 9.x
- Rocky Linux 10.x

# 檔案說明

| 檔案 | 說明 |
| --- | --- |
| `seal-rhel-template.sh` | 自動判斷 RHEL/Rocky 相容系統 8.x、9.x 或 10.x，並清理 VM 範本化前不應保留的主機識別資料。 |

# 使用方式

## curl 直接執行

可直接在要封裝成範本的 VM 上透過 `curl` 下載並執行，script 會由 `sudo bash` 以 root 權限執行。

建議先使用 `--dry-run` 確認會執行的動作：

```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/Seal_RHEL_VM/seal-rhel-template.sh | sudo bash -s -- --dry-run
```

確認後可執行互動式清理，script 會在清理前詢問是否繼續：

```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/Seal_RHEL_VM/seal-rhel-template.sh | sudo bash
```

互動式確認會從 `/dev/tty` 讀取輸入，因此透過 `curl | sudo bash` 執行時仍可輸入確認。若執行環境沒有互動式 terminal，請改用 `--yes`。

非互動式執行時請加入 `--yes`，script 不會停下來等待確認，適合自動化流程使用：

```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/Seal_RHEL_VM/seal-rhel-template.sh | sudo bash -s -- --yes
```

如果要在清理完成後自動關機：

```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/Seal_RHEL_VM/seal-rhel-template.sh | sudo bash -s -- --yes --poweroff
```

`bash` 與 `bash -s --` 的差異：

- 不需要傳入參數時，可以直接使用 `curl ... | sudo bash`，script 會以互動式模式執行。
- 需要傳入 `--dry-run`、`--yes`、`--poweroff` 等 script 參數時，請使用 `sudo bash -s --`。

`bash -s --` 的用途如下：

- `-s`：要求 `bash` 從標準輸入讀取 script，也就是執行 `curl` 下載下來的內容。
- `--`：結束 `bash` 自己的參數解析，後面的 `--dry-run`、`--yes`、`--poweroff` 會傳給 `seal-rhel-template.sh`。

如果沒有加入 `-s`，例如：

```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/Seal_RHEL_VM/seal-rhel-template.sh | sudo bash -- --yes
```

`bash` 會把 `--yes` 當成要執行的檔案名稱，而不是傳給 script 的參數，因此不會正確執行 `curl` 下載的 script。

## 手動下載執行

也可以先將 script 複製到要封裝成範本的 VM，並確認使用 root 權限執行。

```bash
chmod +x seal-rhel-template.sh
sudo ./seal-rhel-template.sh --dry-run
sudo ./seal-rhel-template.sh --yes
```

如果要在清理完成後自動關機：

```bash
sudo ./seal-rhel-template.sh --yes --poweroff
```

# 參數

| 參數 | 說明 |
| --- | --- |
| `--dry-run` | 僅顯示會執行的動作，不修改系統。 |
| `--yes` | 略過互動確認，適合自動化流程使用。 |
| `--poweroff` | 清理完成後執行 `systemctl poweroff` 關機。 |
| `-h`, `--help` | 顯示使用說明。 |

# Script 執行內容

## 自動判斷系統版本

Script 會讀取 `/etc/os-release`，確認作業系統屬於 RHEL/Rocky 相容系列，並判斷主要版本為 8、9 或 10。若不是 RHEL/Rocky 相容的 8.x、9.x 或 10.x，script 會停止執行。

## 取消 RHEL 註冊

當系統識別為 RHEL 且存在 `subscription-manager` 時，會執行：

```bash
subscription-manager unregister
subscription-manager remove --all
subscription-manager clean
```

Rocky Linux 會略過此步驟。

## 清除網路識別資訊

Script 會清除下列檔案中的 MAC、UUID、NetworkManager 連線唯一識別資訊與介面名稱綁定：

- `/etc/sysconfig/network-scripts/ifcfg-*`
- `/etc/NetworkManager/system-connections/*.nmconnection`

同時會刪除：

```bash
/etc/udev/rules.d/70-persistent-*
```

## 重設 hosts 與清空 DNS resolver

Script 會將 `/etc/hosts` 重設為標準 loopback 內容，清除 VM 範本不應保留的自訂主機/IP 對應：

```bash
127.0.0.1   localhost localhost.localdomain localhost4 localhost4.localdomain4
::1         localhost localhost.localdomain localhost6 localhost6.localdomain6
```

同時會清空 `/etc/resolv.conf` 內容；若 `/etc/resolv.conf` 是 symlink，script 會改建為空白 regular file，避免清空 symlink 指向的 runtime 目標：

```bash
/etc/resolv.conf
```

## 重設主機名稱

```bash
hostnamectl set-hostname localhost.localdomain
```

## 刪除 SSH Host Keys

```bash
rm -f /etc/ssh/ssh_host_*
```

新的 SSH host keys 會在 VM 從範本開機後由系統重新產生。

## 重設 Machine ID

RHEL/Rocky 8.x：

```bash
rm -f /var/lib/dbus/machine-id
printf 'uninitialized\n' > /etc/machine-id
```

RHEL/Rocky 9.x 與 10.x：

```bash
rm -f /var/lib/dbus/machine-id
rm -f /etc/machine-id
printf 'uninitialized\n' > /etc/machine-id
chmod 644 /etc/machine-id
```

RHEL/Rocky 9.x 與 10.x 需要保留 `/etc/machine-id` 權限為 `644`，避免影響 dbus-broker 與相關服務。

## 清理選用元件

如果系統存在相關工具或檔案，script 會清理：

- Satellite/Katello consumer package 與 `/etc/rhsm/facts/katello.facts`
- iSCSI initiator name：`/etc/iscsi/initiatorname.iscsi`
- cloud-init logs 與 seed data
- Red Hat Insights 註冊

## 清除 Shell History

Script 會針對 root 與一般使用者家目錄下的 `.bash_history` 執行：

```bash
history -c
history -w
```

執行時會透過 `HISTFILE` 指定目標 `.bash_history`，清空寫回後再移除該 history 檔案。

# 注意事項

- 請先使用 `--dry-run` 確認動作。
- 必要清理步驟失敗時，script 會停止執行；選用元件清理失敗時，script 會記錄訊息並繼續。
- 執行前請確認 VM 不再需要保留目前的註冊、網路、SSH host key、machine-id 與 history 資料。
- 清理完成後應關機，再將 VM 轉換為範本。
