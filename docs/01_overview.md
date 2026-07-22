# 專案腳本總攬與架構評估報告 (Overview & Architecture Assessment)

> **建立時間**：2026-07-22  
> **專案名稱**：Script Container Docs (`script-container-docs`)  
> **審查範圍**：全專案自動化腳本、VM 封裝工具、Proxmox ISO 同步腳本及容器配置

---

## 1. 專案背景與目錄架構

本專案主要包含用於自動化維運、虛擬機 (VM) 範本建置、Proxmox VE 環境整合、Kubernetes 節點前置準備以及 Docker 容器部署之各類腳本與設定檔。

整體專案目錄結構與各模組功能簡介如下：

```
script-container-docs/
├── Inital-setup/                # [舊版] RHEL 9 首次開機互動式網路與 Hostname 設定腳本
│   ├── initial-setup.sh
│   └── 99-firstboot.sh
├── RHEL-Family-Temp/            # [改良版] RHEL 系列 (RHEL/Rocky) 開機設定與範本封裝腳本
│   ├── initial-setup.sh
│   ├── 99-firstboot.sh
│   ├── seal-rhel-template.sh
│   └── CODE_REVIEW_REPORT.md    # 歷史 Code Review 紀錄
├── Seal_RHEL_VM/                # [獨立封裝] RHEL VM 範本清理與封裝腳本
│   └── seal-rhel-template.sh
├── pve_link_iso/                # Proxmox VE ISO 自動符號連結 (Symlink) 同步工具
│   ├── pve_link_iso.sh          # 現行最新版同步腳本
│   └── Old/
│       └── pve_link_iso_old.sh  # 舊版同步腳本 (含管道子 Shell 變數作用域 Bug)
├── k8s_env_init/                # Kubernetes 節點環境初始化腳本 (跨 RHEL/Debian)
│   └── k8s_env_initialization.sh
├── Container/                   # Docker 容器部署配置
│   └── ollama/
│       └── docker-compose.yml   # Ollama + Open WebUI 部署檔
├── k8s_install/                 # Kubernetes 1.36 部署手冊 (Markdown)
└── docs/                        # 本次完整審查與優化報告目錄
```

---

## 2. 審查對象腳本矩陣 (Script Inventory Matrix)

| 腳本路徑 | 主要功能說明 | 支援作業系統 / 環境 | 風險 / 問題數量 | 建議優先權 |
|---|---|---|:---:|:---:|
| `Inital-setup/initial-setup.sh` | 首次開機互動式設定 IP、Gateway、DNS 與 Hostname | RHEL 9 / NetworkManager | 6 項 | 🔴 高 (Critical) |
| `Inital-setup/99-firstboot.sh` | `/etc/profile.d` 觸發首次開機設定 | RHEL 9 (profile.d) | 3 項 | 🟡 中 (Medium) |
| `Seal_RHEL_VM/seal-rhel-template.sh` | 封裝 VM 範本前清理機器識別資料 (Machine-ID, MAC, SSH) | RHEL 8/9/10, Rocky | 5 項 | 🔴 高 (Critical) |
| `RHEL-Family-Temp/initial-setup.sh` | 改良版開機設定腳本 (加入輸入驗證與位元運算 CIDR 轉換) | RHEL / Rocky / Alma | 4 項 | 🟡 中 (Medium) |
| `RHEL-Family-Temp/seal-rhel-template.sh` | 改良版範本清理腳本 | RHEL / Rocky | 3 項 | 🟢 低 (Low) |
| `pve_link_iso/pve_link_iso.sh` | Proxmox VE 掃描來源 ISO 並建立符號連結 | Proxmox VE (PVE 7/8) | 4 項 | 🔴 高 (Critical) |
| `pve_link_iso/Old/pve_link_iso_old.sh` | 舊版 ISO 連結腳本 | Proxmox VE | 3 項 (含語法死結) | 🔴 高 (Critical) |
| `k8s_env_init/k8s_env_initialization.sh` | 關閉防火牆/Swap、載入核心模組、設定 sysctl 及自動驗證 | RHEL / Rocky / Ubuntu / Debian | 2 項 | 🟢 低 (Low) |
| `Container/ollama/docker-compose.yml` | 部署 Ollama AI 與 Open-WebUI 服務 | Docker / Docker Compose | 2 項 | 🟡 中 (Medium) |

---

## 3. 問題等級與分類標準 (Severity Classification)

本次審查將所有發現的問題劃分為四個等級：

1. 🔴 **高風險 / 關鍵缺陷 (Critical / High)**：
   * 會導致程式執行中斷、語法崩潰、資料遺失、死結、系統服務異常或安全性漏洞。
   * 範例：`pve_link_iso_old.sh` 管道子 Shell 變數作用域失效導致計數恆為 0；`initial-setup.sh` 缺驗證導致 `nmcli` 參數錯位；`seal-rhel-template.sh` 破壞 `/etc/hosts` 自訂解析與非法 Machine-ID。

2. 🟡 **中風險 / 系統穩定性 (Medium)**：
   * 在特定情境下（如多終端登入、SSH 連線、無 GPU 環境）會引發非預期行為或執行失敗。
   * 範例：`99-firstboot.sh` 阻擋 SSH 登入觸發；`initial-setup.sh` 缺乏併發鎖 (Lock) 導致多重登入衝突；Docker Compose 浮動標籤與硬性 GPU 綁定。

3. 🟢 **低風險 / 邊緣情境 (Low)**：
   * 不影響核心功能運作，但在程式規範、錯誤訊息提示或邊緣情況下尚有改進空間。
   * 範例：單一網卡時重複詢問使用者；未引號變數展開可能觸發路徑萬用字元展開 (Globbing)；DNS 字串前後空白未剔除。

4. 💡 **最佳實踐 / 程式碼優化 (Best Practice)**：
   * 提升程式碼可讀性、維護性、POSIX 相容性與日後擴充能力。
   * 範例：冗餘命令清理、統一日誌輸出格式、模組化驗證函式抽離。

---

## 4. 總結評估

本專案之腳本具備高度的實用性，特別是在 **RHEL 系統初始化**、**Kubernetes 環境建置** 與 **Proxmox VE 自動化維運** 上展現了明確的需求導向。然而，部分舊版與過渡腳本中存在輸入驗證缺失、死結邏輯、檔案覆寫過度及邏輯缺陷。

透過 `docs/` 內後續章節之分析與修正建議，可將所有腳本提升至 **企業級資安與高可用自動化維運標準**。
