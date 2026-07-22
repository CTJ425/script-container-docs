# Script & Container Documentation (script-container-docs)

此專案收集了用於虛擬化、容器化與系統管理的自動化腳本與設定檔。您可以透過下方的連結快速跳轉至各個目錄：

## 快速連結 (Quick Links)

* 📦 **[RHEL-Family-Temp](./RHEL-Family-Temp)** - RHEL/Rocky VM 範本整合封裝與首次開機引導設定套件（一鍵封裝與開箱即用設定）。
* 🐳 **[Container](./Container)** - 容器相關設定檔（包含 Ollama 部署）。
* ☸️ **[k8s Environment Init](./k8s_env_init)** - Kubernetes 基礎系統環境建置與初始化腳本。
* ☸️ **[k8s Install](./k8s_install)** - Kubernetes 叢集部署手冊（CRI-O + Calico / Rocky Linux）。
* 🔗 **[PVE Link ISO](./pve_link_iso)** - Proxmox VE 中用以連結/下載 ISO 映像檔的腳本。

---

## 模組說明 (Modules Summary)

### 🐳 [Container](./Container)
提供容器化服務的部署定義檔：
- **`ollama/docker-compose.yml`**: 可快速建立 Ollama 服務，執行本地的大型語言模型 (LLM)。

### 📦 [RHEL-Family-Temp](./RHEL-Family-Temp)
整合虛擬機安全封裝與開機引導設定的一體化解決方案：
- **`seal-rhel-template.sh`**: 整合式一鍵封裝主腳本（自動清理並裝載設定檔）。
- **`initial-setup.sh`**: 首次開機引導設定精靈（引導設定主機名稱與靜態 IPv4 網路卡）。
- **`99-firstboot.sh`**: profile 登入觸發器（偵測互動式本地 TTY 登入以執行引導精靈）。

### ☸️ [k8s Environment Init](./k8s_env_init)
專門為安裝 Kubernetes (k8s) 前置環境準備的腳本：
- **`k8s_env_initialization.sh`**: 快速停用 Swap、調整 sysctl 核心參數、安裝必要基礎套件，以符合 Kubernetes 的執行環境要求。

### ☸️ [k8s Install](./k8s_install)
Kubernetes 叢集部署文件：
- **`README.md`**: 說明如何在 Rocky Linux 9.8 上以 CRI-O、kubeadm 與 Calico 建置 Kubernetes 1.36 叢集，包含節點規劃、系統前置準備、Control Plane 初始化、Worker 加入與 CNI 安裝流程。

### 🔗 [PVE Link ISO](./pve_link_iso)
Proxmox VE 環境下的便利工具：
- **`pve_link_iso.sh`**: 用以軟連結或是自動同步/下載 ISO 映像檔至 PVE 的存放目錄，簡化系統安裝的前置流程。

---

## 異動紀錄 (Changelog)

### 2026-07-22 — 全專案腳本審查、修正與舊版清理

本次異動由 AI 交叉審查流程完成（agy/Gemini 審查與修改 → Claude 逐項驗證裁決與獨立 code review），
完整報告見 [`docs/`](./docs)（`01`–`04` 為 agy 原始審查報告，`05_verification_report.md` / `.html` 為驗證與修正結果報告）。

**腳本修正：**
- `RHEL-Family-Temp/initial-setup.sh`（含 `seal-rhel-template.sh` 內嵌副本同步）：
  - 新增 `/run/initial-setup.lock` 原子併發鎖，防止多重登入同時觸發設定精靈
  - 單一網卡環境自動選取，不再要求手動輸入
  - DNS 輸入轉換後修剪首尾空白
  - `/etc/hosts` 主機名稱更新改用 word-boundary 匹配：移除舊主機名、防止相似字首誤判與重複累積
- `RHEL-Family-Temp/seal-rhel-template.sh`：
  - OS 偵測顯式加入 `almalinux`（文件化，原本經 `ID_LIKE` 已可通過）
  - RHEL 8 的 machine-id 重置改為空檔（systemd 239 相容）；RHEL 9/10 維持 `uninitialized`（systemd first-boot 官方機制）
- `pve_link_iso/pve_link_iso.sh`：同名 ISO 跳過時顯示明確警告（含完整來源路徑），並新增獨立跳過計數
- `Container/ollama/docker-compose.yml`：映像鎖定版本（`ollama/ollama:0.32.2`、`open-webui:v0.10.2`）
- `Container/ollama/docker-compose.cpu.yml`：**新增** CPU-only override（需 Docker Compose ≥ v2.24）

**舊版清理：**
- 刪除封存舊版目錄 `Inital-setup/`、`Seal_RHEL_VM/`、`pve_link_iso/Old/`
  （功能均已由 `RHEL-Family-Temp/` 與 `pve_link_iso/pve_link_iso.sh` 現行版取代，移除以避免審查與維護混淆）

---

## 授權條款 (License)

本專案採用 MIT 授權條款，詳見各資料夾中的 `LICENSE` 檔案。
