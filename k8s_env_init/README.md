# Kubernetes Environment Initialization

這個 repository 提供一支 Linux 主機初始化腳本，用來套用 Kubernetes 節點常見的前置設定。

## 腳本

- `k8s_env_initialization.sh`

## 主要功能

腳本會自動判斷作業系統家族（RHEL/Rocky 家族 vs. Debian/Ubuntu 家族），並動態執行對應的環境設定：

1. **作業系統偵測**：讀取 `/etc/os-release` 自動判定發行版與主版本號。
2. **停用防火牆**：
   - RHEL/Rocky 家族：關閉並停用 `firewalld`。
   - Debian/Ubuntu 家族：關閉並停用 `ufw`。
3. **安全模組設定 (SELinux / AppArmor)**：
   - **RHEL-compatible 家族**：使用 `grubby` 加入 `selinux=0` 核心參數，並修改 `/etc/selinux/config` 將 `SELINUX` 設為 `disabled`。
   - **Debian/Ubuntu 家族**：自動跳過此步驟（因預設使用 K8s 原生相容之 AppArmor，毋需關閉）。
4. **停用 Swap**：關閉目前啟用的 Swap 分割區，並以冪等方式註解 `/etc/fstab` 中的 swap 載入項目。
5. **載入核心模組**：建立 `/etc/modules-load.d/crio.conf` 並立即載入 `overlay` 與 `br_netfilter`。
6. **設定 Sysctl 核心參數**：建立 `/etc/sysctl.d/99-kubernetes-cri.conf` 並執行 `sysctl --system` 套用。
7. **執行後驗證摘要**：列出偵測到的 OS，以及 firewall、SELinux/AppArmor、swap、kernel modules、sysctl 等項目的目前狀態。
8. **詢問是否立即重開機**：RHEL 家族特別提示（因 SELinux 變更需重啟方能生效）。

## 支援環境與適合版本

本環境設定腳本與設定方式適用於以下 Linux 發行版及版本：

| 作業系統家族 | 建議/適合版本 | 說明 |
| :--- | :--- | :--- |
| **RHEL / Rocky / AlmaLinux / CentOS** | 8.x, 9.x, **10.x** | 企業級常用環境。腳本會透過 `grubby` 加入 `selinux=0` 核心參數，並將 `/etc/selinux/config` 設為 `SELINUX=disabled`。 |
| **Fedora** | Current supported releases | RHEL-like 家族。腳本會套用與 RHEL-compatible 相同的 SELinux、防火牆、swap、kernel module 與 sysctl 設定。 |
| **Ubuntu** | 20.04 LTS, 22.04 LTS, **24.04 LTS 及以後版本 (例如 24.10, 26.04)** | 社群最常用發行版。不使用 `grubby`，且預設使用 AppArmor (Kubernetes 原生支援，腳本會自動跳過 SELinux 停用步驟，亦不需手動關閉 AppArmor)。 |
| **Debian** | 11 (Bullseye), 12 (Bookworm), **13 (Trixie)** | 輕量且穩定。環境設定原則與 Ubuntu 相同，腳本會自動識別並處理。 |

## 使用方式

### 方法 A：直接線上下載並執行 (適合快速部署)
```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/script-container-docs/main/k8s_env_init/k8s_env_initialization.sh | sudo bash
```

### 方法 B：下載 Raw 腳本至本機，檢查後執行 (推薦)
您可以使用以下 `curl` 指令將 Raw 腳本下載至本地目錄：
```bash
curl -fsSL -O https://raw.githubusercontent.com/CTJ425/script-container-docs/main/k8s_env_init/k8s_env_initialization.sh
```
或使用 `wget` 指令下載：
```bash
wget https://raw.githubusercontent.com/CTJ425/script-container-docs/main/k8s_env_init/k8s_env_initialization.sh
```

下載完成後，您可以賦予執行權限並以 root 權限執行：
```bash
chmod +x k8s_env_initialization.sh
sudo ./k8s_env_initialization.sh
```

腳本執行完成後建議重新開機，使部分核心參數與安全模組設定（如 SELinux）完整生效。

腳本在詢問是否重新開機前，會先輸出 `Verification Summary`，逐項顯示目前抓取到的 OS 與各調整項目的驗證結果。標示為 `OK` 的項目代表目前檢查通過；標示為 `WARN` 的項目代表未生效、無法驗證，或需要重開機後才會完整套用。

---

## RHEL-compatible 自動處理說明

同一支 `k8s_env_initialization.sh` 已內建 RHEL/Rocky/AlmaLinux/CentOS 自動判斷與處理流程。只要依照上方「使用方式」執行腳本即可，不需要在 RHEL-compatible 主機上另外手動輸入以下設定指令。

腳本在偵測到 RHEL-compatible 家族後會自動執行：

1. 停用並 disable `firewalld`。
2. 停用 SELinux：使用 `grubby` 加入 `selinux=0`，並將 `/etc/selinux/config` 設為 `SELINUX=disabled`。
3. 關閉目前啟用的 swap，並註解 `/etc/fstab` 中的 swap 項目。
4. 載入 `overlay` 與 `br_netfilter` kernel modules。
5. 寫入並套用 Kubernetes 所需 sysctl 參數。

以下指令僅作為腳本內部行為參考，或在需要手動除錯時使用。

### 1. 停用防火牆 (firewalld)
```bash
sudo systemctl stop firewalld
sudo systemctl disable firewalld
```

### 2. 停用 SELinux
```bash
sudo grubby --update-kernel ALL --args selinux=0
sudo sed -i 's/^SELINUX=.*/SELINUX=disabled/g' /etc/selinux/config
```

### 3. 關閉 Swap
```bash
# 立即關閉所有 swap 分割區
sudo swapoff -a

# 永久關閉：將 /etc/fstab 中的 swap 設定行註解掉
sudo sed -r -i.bak '/\s+swap\s+/s/^#*/#/' /etc/fstab
```

### 4. 載入必要核心模組
```bash
# 建立載入設定檔
sudo tee /etc/modules-load.d/crio.conf <<EOF
overlay
br_netfilter
EOF

# 立即載入核心模組
sudo modprobe overlay
sudo modprobe br_netfilter
```

### 5. 設定 Sysctl 核心參數
```bash
# 建立 sysctl 設定檔
sudo tee /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# 立即套用核心參數
sudo sysctl --system
```

---

## Ubuntu/Debian 自動處理說明

同一支 `k8s_env_initialization.sh` 已內建 Ubuntu/Debian 自動判斷與處理流程。只要依照上方「使用方式」執行腳本即可，不需要在 Ubuntu/Debian 主機上另外手動輸入以下設定指令。

腳本在偵測到 Ubuntu/Debian 家族後會自動執行：

1. 停用並 disable `ufw`。
2. 跳過 SELinux 設定，保留 AppArmor 預設狀態。
3. 關閉目前啟用的 swap，並註解 `/etc/fstab` 中的 swap 項目。
4. 載入 `overlay` 與 `br_netfilter` kernel modules。
5. 寫入並套用 Kubernetes 所需 sysctl 參數。

以下指令僅作為腳本內部行為參考，或在需要手動除錯時使用。

### 1. 停用防火牆 (UFW)
```bash
sudo systemctl stop ufw
sudo systemctl disable ufw
```

### 2. 關閉 Swap
```bash
# 立即關閉所有 swap 分割區
sudo swapoff -a

# 永久關閉：將 /etc/fstab 中的 swap 設定行註解掉
sudo sed -r -i.bak '/\s+swap\s+/s/^#*/#/' /etc/fstab
```

### 3. 載入必要核心模組
```bash
# 建立載入設定檔
sudo tee /etc/modules-load.d/crio.conf <<EOF
overlay
br_netfilter
EOF

# 立即載入核心模組
sudo modprobe overlay
sudo modprobe br_netfilter
```

### 4. 設定 Sysctl 核心參數
```bash
# 建立 sysctl 設定檔
sudo tee /etc/sysctl.d/99-kubernetes-cri.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
net.bridge.bridge-nf-call-ip6tables = 1
EOF

# 立即套用核心參數
sudo sysctl --system
```

### 5. 安全模組說明 (AppArmor)
* **無需關閉 AppArmor**：與 RHEL/Rocky 的 SELinux 不同，Kubernetes 與主流 Container Runtime (如 containerd、CRI-O) 預設即完整支援 AppArmor 安全規範。因此，在 Ubuntu/Debian 下**不需關閉** AppArmor，維持其預設啟動狀態即可。

---

## 檢查結果

- 語法檢查：`bash -n k8s_env_initialization.sh` 通過
- `shellcheck k8s_env_initialization.sh` 通過
- 已修正 OS 判斷流程：無法識別的 Linux 發行版會中止，不會誤走 RHEL/firewalld 分支。
- 已修正 RHEL-compatible SELinux 流程：所有 RHEL-compatible 版本皆透過 `grubby` 加入 `selinux=0`，並將 `/etc/selinux/config` 設為 `SELINUX=disabled`。
- 已修正執行順序問題：腳本會先載入 `br_netfilter`，再執行 `sysctl --system`。部分系統在 `br_netfilter` 尚未載入時不會存在 `net.bridge.*` sysctl key，可能導致腳本在 `set -e` 下中斷。

## 注意事項

- 腳本會修改系統層級設定，請只在準備作為 Kubernetes 節點的主機上執行。
- `/etc/fstab` 會被原地修改，並產生 `/etc/fstab.bak` 備份。
- `firewalld` 或 `ufw` 不存在或已停用時，腳本會輸出提示並繼續。
- `grubby` 不存在時，腳本會跳過 kernel argument 更新並繼續；`swapoff`、`sysctl`、`modprobe` 任一必要指令失敗時，腳本會因為 `set -e` 中止。
- 腳本不會安裝 container runtime、`kubelet`、`kubeadm` 或 `kubectl`，只負責 Kubernetes 前置系統設定。
