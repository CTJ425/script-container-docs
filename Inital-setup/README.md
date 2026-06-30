# RHEL 9 First Boot Initialization Template

本專案提供一套自動化腳本，旨在為 Red Hat Enterprise Linux 9 (RHEL 9) 系統建立類似商用網路設備（如 Switch/Router）的「開箱即用」體驗。

透過此腳本，系統管理員在製作 VM Template（虛擬機範本）後，新部署的機器於 **第一次使用 root 登入時**，將自動觸發互動式設定精靈，引導使用者設定 **主機名稱 (Hostname)** 與 **網路組態 (Network Configuration)**。

## 目錄 (Table of Contents)

- [專案說明](#專案說明)
- [功能特點](#功能特點)
- [適用環境與注意事項](#適用環境與注意事項)
- [檔案結構](#檔案結構)
- [部署步驟](#部署步驟)
- [使用方式](#使用方式)

## 專案說明

在大量部署虛擬機或交付系統給終端用戶時，通常需要手動設定 IP 位址與主機名稱。本專案透過 `profile.d` 機制與 `nmcli` 工具，將此流程標準化與自動化。

一旦設定完成，系統會生成鎖定檔案 (Flag file)，確保此精靈不會在後續登入中重複執行，回歸正常的 Shell 操作環境。

## 功能特點

* **自動觸發**：僅在 `root` 使用者首次登入時執行。
* **互動式介面**：透過簡單的 CLI 對話視窗引導設定。
* **主機名稱設定**：使用 `hostnamectl` 立即修改系統名稱。
* **網路設定**：整合 `nmcli`，支援 DHCP 與 Static IP (IPv4) 設定。
* **防止重複執行**：設定完成後自動建立旗標檔案，防止二次干擾。

## 適用環境與注意事項

### 適用版本
* **OS**: Red Hat Enterprise Linux 9 (RHEL 9)
* **相容性**: 本腳本亦理論上相容於 binary compatible 的發行版（如 Rocky Linux 9, AlmaLinux 9），但主要針對 RHEL 9 進行設計。

### 注意事項
1.  **NetworkManager**: 本腳本高度依賴 `NetworkManager` 服務及 `nmcli` 指令，請確保系統未停用此服務。
2.  **Root 權限**: 觸發機制設計為針對 `root` (UID 0) 生效。
3.  **SSH 限制**: 預設腳本包含 `[ -z "$SSH_TTY" ]` 判斷，意即**僅在 Console (本機終端) 登入時觸發**。若希望 SSH 遠端登入也能觸發，請修改 `99-firstboot.sh` 移除該判斷式。
4.  **範本製作**: 在封裝成 Template 之前，務必確保旗標檔案不存在。

## 檔案結構

```text
.
├── initial-setup.sh    # 主要設定邏輯腳本 (互動式精靈)
├── 99-firstboot.sh     # 觸發腳本 (放置於 /etc/profile.d/)
└── README.md           # 專案說明文件
```

## 部署步驟

請依照以下步驟將腳本部署至您的「母版 (Master Image)」或「範本機器」中。

### 1. 安裝主設定腳本
將 `initial-setup.sh` 複製到系統路徑並賦予執行權限：

```bash
cp initial-setup.sh /usr/local/bin/initial-setup.sh
```
```bash
chmod +x /usr/local/bin/initial-setup.sh
```

### 2. 安裝觸發腳本
將 `99-firstboot.sh` 複製到 profile 目錄，使其在登入時生效：

```bash
cp 99-firstboot.sh /etc/profile.d/99-firstboot.sh
```
```bash
chmod +x /etc/profile.d/99-firstboot.sh
```

## 使用方式

1.  使用此 Template 部署一台新的虛擬機。
2.  開啟電源並透過 Console 介面登入 `root` 帳號。
3.  系統將自動進入設定引導畫面：
    ```text
    ==========================================================
     Welcome to RHEL 9 Initial System Setup
     This script will run only once on the first root login.
    ==========================================================
    ```
4.  依序輸入**主機名稱**、選擇**網卡介面**、設定 **IP/Netmask/Gateway/DNS**。
5.  腳本執行完畢後會詢問是否重開機。
6.  下次登入時，系統將直接進入標準 Shell 提示字元。

---
**License**
MIT License
