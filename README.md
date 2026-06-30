# Script & Container Documentation (script-container-docs)

此專案收集了用於虛擬化、容器化與系統管理的自動化腳本與設定檔。您可以透過下方的連結快速跳轉至各個目錄：

## 快速連結 (Quick Links)

* 🛠️ **[Inital-setup](./Inital-setup)** - 系統安裝後的基礎初始化與首次開機設定腳本。
* 🐳 **[Container](./Container)** - 容器相關設定檔（包含 Ollama 部署）。
* 🛡️ **[Seal RHEL VM](./Seal_RHEL_VM)** - 用於清理並封裝 Red Hat Enterprise Linux (RHEL) 虛擬機範本的腳本。
* ☸️ **[k8s Environment Init](./k8s_env_init)** - Kubernetes 基礎系統環境建置與初始化腳本。
* 🔗 **[PVE Link ISO](./pve_link_iso)** - Proxmox VE 中用以連結/下載 ISO 映像檔的腳本。

---

## 模組說明 (Modules Summary)

### 🛠️ [Inital-setup](./Inital-setup)
包含作業系統安裝完成後的自動化腳本：
- **`initial-setup.sh`**: 基礎系統設定（如語系、時區、套件更新等）。
- **`99-firstboot.sh`**: 針對虛擬機首次啟動時所進行的客製化環境調整。

### 🐳 [Container](./Container)
提供容器化服務的部署定義檔：
- **`ollama/docker-compose.yml`**: 可快速建立 Ollama 服務，執行本地的大型語言模型 (LLM)。

### 🛡️ [Seal RHEL VM](./Seal_RHEL_VM)
針對 RHEL 虛擬機模版化（Template）的腳本：
- **`seal-rhel-template.sh`**: 清理系統殘留的暫存、機器 ID (machine-id)、網卡 UUID 及歷史紀錄，以便於安全地複製與封裝為金鑰模版。

### ☸️ [k8s Environment Init](./k8s_env_init)
專門為安裝 Kubernetes (k8s) 前置環境準備的腳本：
- **`k8s_env_initialization.sh`**: 快速停用 Swap、調整 sysctl 核心參數、安裝必要基礎套件，以符合 Kubernetes 的執行環境要求。

### 🔗 [PVE Link ISO](./pve_link_iso)
Proxmox VE 環境下的便利工具：
- **`pve_link_iso.sh`**: 用以軟連結或是自動同步/下載 ISO 映像檔至 PVE 的存放目錄，簡化系統安裝的前置流程。

---

## 授權條款 (License)

本專案採用 MIT 授權條款，詳見各資料夾中的 `LICENSE` 檔案。
