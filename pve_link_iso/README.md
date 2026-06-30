# PVE ISO Link Sync

這個專案提供一支 Bash 腳本，用來掃描指定來源目錄中的 ISO 檔案，並在 Proxmox VE 的 ISO 目錄建立 symbolic link。

## 檔案

- `pve_link_iso.sh`: 主要執行腳本。
- `Old/pve_link_iso_old.sh`: 舊版備份腳本。

## 腳本用途

腳本會從 `SOURCE_DIR` 開始遞迴搜尋 `.iso` 檔案，略過 Proxmox VE 的目標 ISO 目錄與 Synology 常見的 `@eaDir` 目錄，然後在 `TARGET_DIR` 中建立同名 symbolic link。

預設設定：

```bash
SOURCE_DIR="/mnt/pve/ISO"
TARGET_DIR="/mnt/pve/ISO/template/iso"
```

## 執行方式

確認腳本有執行權限：

```bash
chmod +x pve_link_iso.sh
```

執行腳本：

```bash
./pve_link_iso.sh
```

如果在 Proxmox VE 主機上目標目錄需要較高權限，請使用：

```bash
sudo ./pve_link_iso.sh
```

## Crontab 自動執行

建議先把專案放在 Proxmox VE 主機上的固定路徑，例如：

```bash
/root/pve_link_iso
```

確認腳本可以手動執行成功後，再加入 root 的 crontab：

```bash
sudo crontab -e
```

每天凌晨 3:10 自動同步一次：

```cron
10 3 * * * /root/pve_link_iso/pve_link_iso.sh >> /var/log/pve_link_iso.log 2>&1
```

如果希望每小時同步一次：

```cron
0 * * * * /root/pve_link_iso/pve_link_iso.sh >> /var/log/pve_link_iso.log 2>&1
```

排程設定後可用以下指令確認：

```bash
sudo crontab -l
```

查看最近執行結果：

```bash
sudo tail -n 100 /var/log/pve_link_iso.log
```

注意：

- 請依實際放置位置調整 crontab 內的腳本路徑。
- 建議使用 root crontab，避免目標 ISO 目錄權限不足。
- 腳本內使用絕對路徑，不依賴目前工作目錄，適合由 cron 執行。
- cron 環境變數較少；如有額外指令或掛載需求，請使用絕對路徑或先確認掛載已完成。

## 行為說明

執行時腳本會：

1. 檢查來源目錄是否存在。
2. 檢查目標目錄是否存在。
3. 清除目標目錄中既有的 `.iso` symbolic link。
4. 掃描來源目錄中的 ISO 檔案。
5. 在目標目錄建立新的 symbolic link。
6. 顯示成功建立與失敗建立的數量。

## 注意事項

- 目標目錄中既有的 `.iso` symbolic link 會被清除後重建。
- 目標目錄中的一般檔案不會被刪除。
- 目標目錄中的非 `.iso` symbolic link 不會被刪除。
- 如果不同子目錄中有相同檔名的 ISO，目標目錄只能保留一個同名連結。
- 如果建立 link 失敗，請檢查執行權限、目標目錄權限，以及檔案系統是否支援 symbolic link。

## 語法檢查

可以使用以下指令檢查 Bash 語法：

```bash
bash -n pve_link_iso.sh
```
