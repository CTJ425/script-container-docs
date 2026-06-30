# Kubernetes Environment Initialization

這個 repository 提供一支 Linux 主機初始化腳本，用來套用 Kubernetes 節點常見的前置設定。

## 腳本

- `k8s_env_initialization.sh`

## 主要功能

腳本會依序執行以下設定：

1. 停用並關閉 `firewalld`
2. 透過 `grubby` 加入 `selinux=0` kernel argument，讓 SELinux 在重開機後停用
3. 關閉目前啟用的 swap，並把 `/etc/fstab` 中的 swap 設定註解掉
4. 建立 `/etc/modules-load.d/crio.conf`，並立即載入 `overlay` 與 `br_netfilter`
5. 建立 `/etc/sysctl.d/99-kubernetes-cri.conf`，並執行 `sysctl --system`
6. 詢問是否立即重開機

## 使用方式

如果要直接檢查並使用 GitHub 上的 script，可以輸入：

```bash
curl -fsSL https://raw.githubusercontent.com/CTJ425/k8s_env_init/refs/heads/main/k8s_env_initialization.sh | sudo bash
```

或下載到本機後執行：

```bash
sudo bash k8s_env_initialization.sh
```

腳本需要 root 權限。執行完成後建議重開機，因為 SELinux 的停用設定需要重開機才會完整生效。

## 支援環境與假設

這支腳本主要針對使用 `systemd`、`firewalld`、`grubby` 的 RHEL/CentOS/Rocky Linux/AlmaLinux 類系統。若在 Ubuntu/Debian 或未安裝 `grubby` 的環境執行，SELinux 設定步驟可能會失敗。

## 檢查結果

- 語法檢查：`bash -n k8s_env_initialization.sh` 通過
- `shellcheck`：目前本機環境未安裝，未執行
- 已修正執行順序問題：原本腳本先執行 `sysctl --system`，再載入 `br_netfilter`。部分系統在 `br_netfilter` 尚未載入時不會存在 `net.bridge.*` sysctl key，可能導致腳本在 `set -e` 下中斷。現在已改為先載入 kernel modules，再套用 sysctl 設定。

## 注意事項

- 腳本會修改系統層級設定，請只在準備作為 Kubernetes 節點的主機上執行。
- `/etc/fstab` 會被原地修改，並產生 `/etc/fstab.bak` 備份。
- `firewalld` 不存在或已停用時，腳本會輸出提示並繼續。
- `grubby`、`swapoff`、`sysctl`、`modprobe` 任一必要指令失敗時，腳本會因為 `set -e` 中止。
- 腳本不會安裝 container runtime、`kubelet`、`kubeadm` 或 `kubectl`，只負責 Kubernetes 前置系統設定。
