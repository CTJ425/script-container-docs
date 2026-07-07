# Script & Container Documentation (script-container-docs)

此專案收集了用於虛擬化、容器化與系統管理的自動化腳本與設定檔。您可以透過下方的連結快速跳轉至各個目錄：

## 快速連結 (Quick Links)

* 📦 **[RHEL-Family-Temp](./RHEL-Family-Temp)** - RHEL/Rocky VM 範本整合封裝與首次開機引導設定套件（一鍵封裝與開箱即用設定）。
* 🛠️ **[Inital-setup](./Inital-setup)** - 系統安裝後的基礎初始化與首次開機設定腳本。
* 🐳 **[Container](./Container)** - 容器相關設定檔（包含 Ollama 部署）。
* 🛡️ **[Seal RHEL VM](./Seal_RHEL_VM)** - 用於清理並封裝 Red Hat Enterprise Linux (RHEL) 虛擬機範本的腳本。
* ☸️ **[k8s Environment Init](./k8s_env_init)** - Kubernetes 基礎系統環境建置與初始化腳本。
* ☸️ **[k8s Install](./k8s_install)** - Kubernetes 叢集部署手冊（CRI-O + Calico / Rocky Linux）。
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

## 授權條款 (License)

本專案採用 MIT 授權條款，詳見各資料夾中的 `LICENSE` 檔案。
