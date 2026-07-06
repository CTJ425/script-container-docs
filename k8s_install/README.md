# Kubernetes 1.36 叢集部署手冊（CRI-O + Calico / Rocky Linux 9.8）

> 文件撰寫時間：2026-06-30

## 環境規格

| 項目 | 內容 |
|---|---|
| Kubernetes 版本 | v1.36（目前最新穩定版，1.36.2，2026-06-09 釋出） |
| Control Plane 節點 | 1 台 |
| Worker 節點 | 2 台 |
| Container Runtime | CRI-O |
| CNI | Calico（v3.32.1，以 Tigera Operator 安裝，保留 kube-proxy） |
| 作業系統 | Rocky Linux 9.8（kernel 5.14.0-687.10.1） |

> Kubernetes 採 N-2 支援政策，1.36 為目前最新版本；若你的環境偏好較保守的版本，1.35 或 1.34 也仍在官方支援窗口內，僅需把以下指令中的 `v1.36` 換成對應版本即可。

### 主機規劃範例

| Hostname | 角色 | IP |
|---|---|---|
| k8s-cp01 | Control Plane | 10.0.1.10 |
| k8s-wk01 | Worker | 10.0.1.11 |
| k8s-wk02 | Worker | 10.0.1.12 |

請依實際環境替換 IP / hostname。以下標示「**全部節點**」的步驟，CP 與 Worker 都要做；標示「**僅 CP**」或「**僅 Worker**」則只在對應節點執行。

---

## 1. 系統前置準備（全部節點）

### 1.1 設定 Hostname

```bash
# 在對應節點上執行
sudo hostnamectl set-hostname k8s-cp01   # CP
sudo hostnamectl set-hostname k8s-wk01   # Worker1
sudo hostnamectl set-hostname k8s-wk02   # Worker2
```

### 1.2 設定 /etc/hosts

```bash
cat <<EOF | sudo tee -a /etc/hosts
10.0.1.10 k8s-cp01
10.0.1.11 k8s-wk01
10.0.1.12 k8s-wk02
EOF
```

### 1.3 關閉 swap

```bash
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab
```

### 1.4 將 SELinux 設為 permissive（或視需要維持 enforcing）

CRI-O 在 Rocky 9 上可支援 SELinux enforcing，但初次部署建議先設為 permissive，穩定後再視需求調回 enforcing。

```bash
sudo setenforce 0
sudo sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config
```

### 1.5 防火牆設定

簡化測試環境可直接關閉 firewalld；正式環境請改用對應開放埠號。

```bash
sudo systemctl disable --now firewalld
```

若需保留 firewalld，請至少開放：

```bash
# 僅 CP
sudo firewall-cmd --permanent --add-port=6443/tcp
sudo firewall-cmd --permanent --add-port=2379-2380/tcp
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=10257/tcp
sudo firewall-cmd --permanent --add-port=10259/tcp

# 全部節點（Calico）
sudo firewall-cmd --permanent --add-port=10250/tcp
sudo firewall-cmd --permanent --add-port=179/tcp     # Calico BGP
sudo firewall-cmd --permanent --add-port=4789/udp    # VXLAN（Calico 預設封裝模式）
sudo firewall-cmd --permanent --add-port=5473/tcp    # Typha（若啟用）

sudo firewall-cmd --reload
```

### 1.6 核心模組與 sysctl

```bash
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sudo sysctl --system
```

### 1.7 時間同步

```bash
sudo dnf install -y chrony
sudo systemctl enable --now chronyd
```

---

## 2. 安裝 CRI-O（全部節點）

CRI-O 套件已由 `pkgs.k8s.io` 移轉至 openSUSE Build Service（`isv:/cri-o`），版本需對齊 Kubernetes 的 minor 版本（這裡為 1.36）。

```bash
export CRIO_VERSION=v1.36

cat <<EOF | sudo tee /etc/yum.repos.d/cri-o.repo
[cri-o]
name=CRI-O
baseurl=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://download.opensuse.org/repositories/isv:/cri-o:/stable:/$CRIO_VERSION/rpm/repodata/repomd.xml.key
EOF

sudo dnf install -y cri-o
```

### 2.1 設定 cgroup driver 為 systemd

Rocky Linux 9 預設使用 systemd 作為 init 系統，CRI-O 需與 kubelet 的 cgroup driver 一致（皆使用 `systemd`）。

```bash
sudo mkdir -p /etc/crio/crio.conf.d
cat <<EOF | sudo tee /etc/crio/crio.conf.d/02-cgroup-manager.conf
[crio.runtime]
cgroup_manager = "systemd"
conmon_cgroup = "pod"
EOF
```

### 2.2 啟動 CRI-O

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now crio
sudo systemctl status crio --no-pager
```

---

## 3. 安裝 kubeadm / kubelet / kubectl（全部節點）

```bash
export KUBERNETES_VERSION=v1.36

cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/$KUBERNETES_VERSION/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

sudo dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
sudo systemctl enable --now kubelet
```

> `exclude=` 這行可避免 `dnf update` 時意外把版本升級到下一個 minor 版本；要升級時加上 `--disableexcludes=kubernetes` 即可。

確認版本：

```bash
kubeadm version
kubectl version --client
crictl --version
crio --version    # CRI-O 屬於獨立套件，不包含在 kubeadm/kubectl/crictl 的版本資訊裡，需另外用這個指令確認
```

---

## 4. 初始化 Control Plane（僅 CP）

Calico 預設搭配 kube-proxy 運作（不像 Cilium 需要取代它），因此 `kubeadm init` 不需要加 `--skip-phases=addon/kube-proxy`。Pod CIDR 採用 `10.244.0.0/16`，稍後在 Calico 的 `custom-resources.yaml` 也要設成同一個範圍。

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --apiserver-advertise-address=10.0.1.10 \
  --cri-socket=unix:///var/run/crio/crio.sock \
  --kubernetes-version=v1.36.2
```

初始化完成後，依輸出指示設定 kubectl：

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

記下輸出中的 `kubeadm join` 指令（含 token 與 ca-cert-hash），供 Worker 節點加入使用。Token 預設 24 小時過期，若過期可在 CP 重新產生：

```bash
kubeadm token create --print-join-command
```

---

## 5. Worker 節點加入叢集（僅 Worker）

在 k8s-wk01、k8s-wk02 上分別執行（替換成實際 token / hash）：

```bash
sudo kubeadm join 10.0.1.10:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --cri-socket=unix:///var/run/crio/crio.sock
```

此時節點會是 `NotReady`，因為尚未安裝 CNI（Calico）。

---

## 6. 安裝 Calico CNI（僅 CP，會佈署到全部節點）

本文採用官方推薦的 **Tigera Operator** 方式安裝（而非舊式的單一 manifest），Operator 會自動處理 Typha 擴展、升級與生命週期管理。版本使用目前最新穩定版 **v3.32.1**。

> 補充：Calico v3 CRD 的預設值機制（defaulting）依賴 `MutatingAdmissionPolicy`。此功能在 Kubernetes 1.36 已經 GA 並預設開啟，所以本文件（K8s 1.36）不需要額外開 feature gate；若你日後降版到 1.34 / 1.35，需要手動在 API Server 開啟 `MutatingAdmissionPolicy` feature gate。

### 6.1 安裝 CRD 與 Tigera Operator

```bash
CALICO_VERSION=v3.32.1

kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/v1_crd_projectcalico_org.yaml
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml

kubectl wait --for=condition=Available deployment/tigera-operator \
  -n tigera-operator --timeout=120s
```

### 6.2 套用自訂資源（Installation CR）

下載官方範例並調整 Pod CIDR，使其與步驟 4 的 `--pod-network-cidr` 一致。

```bash
curl https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml -O

# 將預設 192.168.0.0/16 改成與 kubeadm init 一致的 10.244.0.0/16
sed -i 's#cidr: 192\.168\.0\.0/16#cidr: 10.244.0.0/16#' custom-resources.yaml

kubectl create -f custom-resources.yaml
```

`custom-resources.yaml` 內預設使用 VXLAN（`encapsulation: VXLANCrossSubnet`）封裝，適合大部分私有環境（節點間不需要事先打通 BGP 路由）。若節點間網路已可直接路由，可改為 `encapsulation: None` 提升效能，或改用 BGP 模式。

### 6.3 驗證 Calico 狀態

```bash
kubectl wait --for=condition=Available tigerastatus/calico --timeout=300s
kubectl get pods -n calico-system
kubectl get tigerastatus
```

預期 `calico-system` 命名空間下的 `calico-node`（每節點一個）、`calico-kube-controllers`、`calico-typha` 等 pod 皆為 `Running`，且 `tigerastatus` 顯示 `Available`。

### 6.4（選用）安裝 calicoctl

> 注意：`calicoctl` 是獨立的 CLI 工具，**不會**隨 Tigera Operator 或 Calico 元件自動安裝，必須像下面這樣手動下載才能使用 `calicoctl version` 等指令。如果不打算另外安裝 calicoctl，可以直接用 `kubectl` 來確認 Calico 版本與狀態（見下方「不安裝 calicoctl 的替代驗證方式」），不需要、也不能用 `crio --version` 來驗證 Calico 版本 —— `crio --version` 驗證的是 CRI-O（容器執行環境）的版本，跟 Calico（CNI）是兩個不同的元件，兩者沒有對應關係。

```bash
curl -L https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/calicoctl-linux-amd64 -o calicoctl
chmod +x calicoctl
sudo mv calicoctl /usr/local/bin/
calicoctl version
```

**不安裝 calicoctl 的替代驗證方式：**

```bash
# 確認 Tigera Operator 安裝的 Calico 版本
kubectl get installation default -o jsonpath='{.status.calicoVersion}'; echo

# 直接看 calico-node 容器使用的映像版本
kubectl get pods -n calico-system -l k8s-app=calico-node \
  -o jsonpath='{.items[0].spec.containers[0].image}'; echo
```

---

## 7. 確認叢集狀態

```bash
kubectl get nodes -o wide
kubectl get pods -A
```

所有節點應為 `Ready`，`kube-system` 下的 coredns、kube-proxy 等 pod，以及 `calico-system` 下的 calico-node、calico-kube-controllers 等 pod 應為 `Running`。

---

## 8.（選用）Calico 網路政策驗證

可快速建立兩個測試 pod，驗證 NetworkPolicy 是否生效：

```bash
kubectl run nginx --image=nginx --port=80 --expose
kubectl run curl-test --image=curlimages/curl:latest -- sleep 3600

# 套用 NetworkPolicy 前應可連通
kubectl exec curl-test -- curl --max-time 5 http://nginx

# 套用 deny-all 政策
cat <<EOF | calicoctl apply -f -
apiVersion: projectcalico.org/v3
kind: NetworkPolicy
metadata:
  name: deny-all
  namespace: default
spec:
  selector: all()
  types:
  - Ingress
EOF

# 此時應該逾時
kubectl exec curl-test -- curl --max-time 5 http://nginx
```

測試完成後記得清除測試資源：

```bash
calicoctl delete networkpolicy deny-all -n default
kubectl delete pod nginx curl-test
kubectl delete svc nginx
```

---

## 9. 安裝與使用 MetalLB（LoadBalancer 服務）

裸機（bare-metal）/地端 Kubernetes 叢集預設沒有雲端 LB 控制器，`Service type: LoadBalancer` 會永遠卡在 `<pending>`。MetalLB 補上這塊，讓地端叢集也能用 `LoadBalancer` 類型對外曝露服務。本文固定使用 **v0.16.1** manifest tag，並以最簡單的 **Layer2 模式** 示範（不需要 BGP 路由器，靠 ARP/NDP 廣播 IP，適合大多數地端/實驗室環境；若有 BGP 路由器、且想做到多節點同時轉發，可改用 BGP 模式，做法類似但設定資源不同，本文不展開）。

### 9.1 安裝前確認事項

* 確保叢集內**沒有**安裝其他 LoadBalancer controller（例如雲端 CCM），避免互相搶 IP。
* 確認 `kube-proxy` 的 proxy mode。kubeadm 預設使用 `iptables` 模式，這種情況下**不需要**額外設定 strict ARP。只有在你手動把 `kube-proxy` 改成 `ipvs` 模式時，才需要開啟 strict ARP（步驟如下，供需要時參考）：

```bash
# 僅當 kube-proxy 為 IPVS 模式時才需要執行
kubectl get configmap kube-proxy -n kube-system -o yaml | \
  sed -e "s/strictARP: false/strictARP: true/" | \
  kubectl apply -f - -n kube-system

kubectl rollout restart daemonset kube-proxy -n kube-system
kubectl rollout status daemonset kube-proxy -n kube-system
```

* 準備一段**目前網路上未被使用、且與節點同網段**的 IP 區段，留給 MetalLB 配發給 LoadBalancer 服務，例如 `10.0.1.200-10.0.1.220`。

### 9.2 安裝 MetalLB

```bash
METALLB_VERSION=v0.16.1

kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/${METALLB_VERSION}/config/manifests/metallb-native.yaml

kubectl wait --namespace metallb-system \
  --for=condition=ready pod \
  --selector=app=metallb \
  --timeout=120s
```

> 套件版本要與 Kubernetes 版本搭配，正式環境部署前建議至 MetalLB 官方 Installation 頁面 / GitHub Releases 再次確認當下最新的相容版本。

驗證安裝：

```bash
kubectl get pods -n metallb-system -o wide
```

應看到一個 `controller` deployment pod，以及每個節點各一個 `speaker` daemonset pod，皆為 `Running`。

### 9.3 設定 IP 位址池與 Layer2 廣播

```bash
cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 10.0.1.200-10.0.1.220
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
```

確認 CRD 套用成功：

```bash
kubectl get ipaddresspools,l2advertisements -n metallb-system
```

### 9.4 測試 LoadBalancer 服務

```bash
kubectl create deployment nginx-demo --image=nginx --port=80
kubectl expose deployment nginx-demo --port=80 --type=LoadBalancer --name=nginx-lb

# 等待外部 IP 配發完成
kubectl get svc nginx-lb -w
```

確認看到 `EXTERNAL-IP` 從 `<pending>` 變成 MetalLB 配發的 IP（例如 `10.0.1.200`）後，可在同網段的機器上測試連線：

```bash
curl http://10.0.1.200
```

測試完成後清除資源：

```bash
kubectl delete svc nginx-lb
kubectl delete deployment nginx-demo
```

### 9.5 常見問題（MetalLB）

| 症狀 | 排查方向 |
|---|---|
| `EXTERNAL-IP` 一直是 `<pending>` | 確認 `IPAddressPool` / `L2Advertisement` 已套用，且 `default-pool` 還有未分配的 IP：`kubectl describe ipaddresspool default-pool -n metallb-system` |
| 拿到 IP 但外部 ping/連線不到 | 確認該 IP 與節點在同一個 L2 網段；檢查 speaker log：`kubectl logs -n metallb-system -l component=speaker` |
| 多個 LoadBalancer controller 衝突 | 確認叢集內沒有同時跑其他 LB controller（如雲端 CCM），或改用 `loadBalancerClass` 區隔 |
| 用 IPVS 模式時服務不通 | 確認已依 9.1 完成 `strictARP: true` 設定並重啟 `kube-proxy` daemonset |

---

## 10. 安裝與使用 KubeVirt（在 K8s 上跑虛擬機）

KubeVirt 讓你用 Kubernetes 原生的方式（CRD：`VirtualMachine` / `VirtualMachineInstance`）管理傳統虛擬機，跟容器工作負載混合部署在同一個叢集。本文採用目前最新穩定版 **v1.8.4**。

> **版本相容性提醒**：KubeVirt v1.8 官方是對齊 Kubernetes v1.35 開發、並額外支援前兩個版本（即官方驗證範圍約為 v1.33 ~ v1.35）。本文件叢集為 v1.36，屬於比 KubeVirt v1.8 官方驗證範圍更新的版本，實務上通常仍可運作，但並非官方正式驗證組合。建議在正式環境導入前，先到 KubeVirt 官方 [support matrix](https://kubevirt.io/support-matrix/) 確認是否已有對應 v1.36 的更新版本，若追求穩妥，也可考慮把叢集控制在 KubeVirt 官方驗證的 K8s 版本範圍內。

### 10.1 節點前置需求（全部節點，尤其 Worker）

KubeVirt 的 VM 是以「容器包一個 QEMU/KVM 程序」（virt-launcher pod）的形式運作，因此需要節點具備硬體虛擬化能力。

1. **確認 CPU 虛擬化擴充功能已開啟**（實體機需在 BIOS 開啟 Intel VT-x / AMD-V；若節點本身是虛擬機，需開啟該 VM 的巢狀虛擬化）：

```bash
lscpu | grep -E 'Virtualization'
# 或
grep -E 'vmx|svm' /proc/cpuinfo | head -1
```

2. **載入 KVM 核心模組並確認 `/dev/kvm` 存在**：

```bash
sudo modprobe kvm
sudo modprobe kvm_intel   # Intel CPU；AMD 請改用 kvm_amd
ls -l /dev/kvm
```

若沒有 `/dev/kvm`（例如巢狀虛擬化未開啟、或雲端環境不支援硬體虛擬化），KubeVirt 仍可運作，但會退回**軟體模擬（emulation）模式**，效能較差，需在後續 KubeVirt CR 中額外開啟設定（見 10.4 疑難排解）。

3. **安裝 `qemu-kvm` 相關套件方便自行驗證環境**（非必要，僅供檢測）：

```bash
sudo dnf install -y qemu-kvm libvirt virt-host-validate
sudo virt-host-validate qemu
```

4. **SELinux**：若日後將 SELinux 調回 enforcing，需確認 `container-selinux` 版本不低於 2.170.0，避免 virt-launcher 相關的 SELinux context 存取被擋下。本文件目前設定為 permissive，暫不受此限制影響。

### 10.2 安裝 KubeVirt Operator 與 CR

```bash
export KUBEVIRT_VERSION=v1.8.4

# 部署 virt-operator（負責管理 KubeVirt 各元件的生命週期）
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml

# 等待 operator 就緒
kubectl wait --for=condition=Ready pod -l kubevirt.io=virt-operator -n kubevirt --timeout=120s

# 建立 KubeVirt CR，觸發實際安裝（virt-api、virt-controller、virt-handler）
kubectl apply -f https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml

# 等待整套 KubeVirt 安裝完成
kubectl -n kubevirt wait kv kubevirt --for condition=Available --timeout=300s
```

### 10.3 驗證安裝與安裝 virtctl

```bash
kubectl get pods -n kubevirt
```

預期看到 `virt-api`、`virt-controller`（各 2 個副本）、每個節點各一個 `virt-handler`，以及 `virt-operator` 皆為 `Running`。

安裝 `virtctl`（管理 VM 的專用 CLI，例如啟動/關閉/連 console，不會隨 operator 自動安裝在節點上，需另外下載）：

```bash
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/')
curl -L -o virtctl \
  https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${ARCH}
sudo install -m 0755 virtctl /usr/local/bin/virtctl

virtctl version
```

### 10.4 建立第一台測試 VM

```bash
cat <<EOF | kubectl apply -f -
apiVersion: kubevirt.io/v1
kind: VirtualMachine
metadata:
  name: testvm
  namespace: default
spec:
  running: false
  template:
    metadata:
      labels:
        kubevirt.io/domain: testvm
    spec:
      domain:
        cpu:
          cores: 1
        resources:
          requests:
            memory: 512Mi
        devices:
          disks:
            - name: containerdisk
              disk:
                bus: virtio
            - name: cloudinitdisk
              disk:
                bus: virtio
      volumes:
        - name: containerdisk
          containerDisk:
            image: quay.io/containerdisks/cirros:latest
        - name: cloudinitdisk
          cloudInitNoCloud:
            userData: |
              #cloud-config
              password: kubevirt
              chpasswd: { expire: False }
EOF
```

啟動、查看與連線：

```bash
virtctl start testvm

kubectl get vm,vmi

# 連進 VM 的 serial console（離開請按 Ctrl+]）
virtctl console testvm
```

清除測試資源：

```bash
virtctl stop testvm
kubectl delete vm testvm
```

### 10.5 疑難排解

| 症狀 | 排查方向 |
|---|---|
| `virt-handler` 一直 `Init:Error` 或 CrashLoop | 檢查節點是否有 `/dev/kvm`，以及是否為 SELinux 擋下（`journalctl -b \| grep -i denied`） |
| VM 一直卡在 `Scheduling` | `kubectl describe vmi <name>`，常見原因是節點資源不足或缺少必要的 label/taint 容忍 |
| 沒有硬體虛擬化，效能太差可接受 | 在 KubeVirt CR 加上軟體模擬設定：`kubectl -n kubevirt patch kubevirt kubevirt --type=merge --patch '{"spec":{"configuration":{"developerConfiguration":{"useEmulation":true}}}}'`（僅建議測試環境使用，效能明顯較差） |
| `virtctl` 版本與叢集內 KubeVirt 版本不一致 | 用 `kubectl get kubevirt.kubevirt.io/kubevirt -n kubevirt -o=jsonpath="{.status.observedKubeVirtVersion}"` 查詢叢集實際版本，重新下載對應版本的 virtctl |
| 想確認 KubeVirt 是否支援目前的 K8s 版本 | 參考官方 support matrix（https://kubevirt.io/support-matrix/），必要時鎖定較低但已驗證的 K8s 版本 |

---

## 11. 安裝與使用 Gateway API

Gateway API 是 Kubernetes 官方定位的 Ingress 後繼者（`Ingress-NGINX` 已於 2026-03 進入僅維護模式，未來不再有安全更新），提供 `GatewayClass` / `Gateway` / `HTTPRoute` 等角色分離的資源模型。本文採用 Gateway API 目前最新標準版 **v1.6.0（Standard channel）**，並利用**已安裝的 Calico（v3.32.1）內建的 Calico Ingress Gateway** 作為實作 —— 它是以 Tigera Operator 管理、100% 上游 Envoy Gateway 的免費開源發行版，不需要另外安裝 Istio、Envoy Gateway 或其他第三方 Gateway Controller，與本文件既有的 Calico 安裝方式（Tigera Operator）完全共用同一套管理機制。

> 由於 Gateway 資源預設會建立一個 `Service type: LoadBalancer` 來對外曝露，正好可以搭配本文件第 9 節已安裝的 **MetalLB** 取得外部 IP，兩者建議一起使用。

### 11.1 安裝 Gateway API CRDs（Standard Channel）

```bash
kubectl apply --server-side -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.6.0/standard-install.yaml
```

確認 CRD 安裝成功：

```bash
kubectl get crd | grep gateway.networking.k8s.io
```

應看到 `gatewayclasses`、`gateways`、`httproutes`、`referencegrants` 等 CRD。

### 11.2 啟用 Calico Ingress Gateway（建立 GatewayAPI 資源）

建立 `GatewayAPI` 自訂資源後，Tigera Operator 會自動拉取 Envoy Gateway 映像，部署對應的控制平面，並建立好一個名為 `tigera-gateway-class` 的 `GatewayClass`。

```bash
cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: GatewayAPI
metadata:
  name: default
EOF
```

等待相關元件就緒（視環境約需 1~2 分鐘）：

```bash
kubectl get tigerastatus gateway-api-connectivity -w
```

確認 `GatewayClass` 已自動建立：

```bash
kubectl get gatewayclass
kubectl get gatewayclass tigera-gateway-class -o jsonpath='{.spec}' | jq
```

### 11.3 建立 Gateway 與 HTTPRoute

以下示範建立一個對外的 Gateway，並用 HTTPRoute 把流量導到一個測試服務。

```bash
# 先準備一個測試 Deployment 與 Service
kubectl create deployment web-demo --image=nginx --port=80
kubectl expose deployment web-demo --port=80

# 建立 Gateway（會自動建立 type: LoadBalancer 的 Service，由 MetalLB 配發外部 IP）
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: demo-gateway
  namespace: default
spec:
  gatewayClassName: tigera-gateway-class
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: Same
EOF

# 建立 HTTPRoute，把 / 導到 web-demo 服務
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: web-demo-route
  namespace: default
spec:
  parentRefs:
  - name: demo-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: web-demo
      port: 80
EOF
```

等待 Gateway 就緒並取得外部 IP：

```bash
kubectl wait --for=condition=Programmed gateway/demo-gateway --timeout=120s
kubectl get gateway demo-gateway -o jsonpath='{.status.addresses[0].value}'; echo
```

用取得的 IP（例如 MetalLB 配發的 `10.0.1.20x`）測試連線：

```bash
curl http://<GATEWAY_IP>/
```

測試完成後清除資源：

```bash
kubectl delete httproute web-demo-route
kubectl delete gateway demo-gateway
kubectl delete svc web-demo
kubectl delete deployment web-demo
```

### 11.4 疑難排解

| 症狀 | 排查方向 |
|---|---|
| `GatewayClass tigera-gateway-class` 沒有出現 | 確認 `GatewayAPI` CR 已建立、`tigerastatus gateway-api-connectivity` 是否為 `Available`；檢查是否能連外拉取 Envoy Gateway 映像 |
| Gateway 一直沒有 `status.addresses` | 確認 MetalLB 已正確安裝且 `IPAddressPool` 還有可用 IP（見第 9 節）；`kubectl describe gateway demo-gateway` 查看事件 |
| HTTPRoute 建立但流量 404 / 無法連通 | 確認 `parentRefs` 名稱與 `Gateway` 一致，且後端 Service/port 存在；跨 namespace 時需額外建立 `ReferenceGrant` |
| 想同時支援多個對外網域 / TLS | 可在 `Gateway` 的 `listeners` 中增加 `HTTPS` listener 並掛載對應的 TLS Secret，此為進階用法，建議先參考 Calico 官方 Gateway API 文件的 TLS 章節 |

---

## 12. 安裝與使用 TrueNAS CSI

[truenas-csi](https://github.com/truenas/truenas-csi) 是 TrueNAS 官方維護的 Container Storage Interface（CSI）驅動程式，透過 TrueNAS 的 Websocket API 動態建立 NFS（RWX）或 iSCSI（RWO / RWX，RWX 需搭配叢集檔案系統如 GFS2/OCFS2）持久化儲存，並支援容量擴充、快照與 Clone。本文件以 **NFS 模式**為主要示範（免額外安裝節點套件、設定最單純），iSCSI 為選用進階模式。

### 12.1 前置需求確認

| 項目 | 需求 |
|---|---|
| TrueNAS | TrueNAS SCALE 25.10.0 以上，且已在 TrueNAS 開啟 API 存取、至少建立一個 ZFS pool |
| Kubernetes | 1.26 以上（本文件 v1.36 符合） |
| 快照功能 | 需另外安裝 external-snapshotter 的 snapshot-controller（選用） |
| NFS Volume 節點需求 | 無額外套件需求 |
| iSCSI Volume 節點需求 | 所有 Worker 節點需安裝 `open-iscsi`（Rocky/RHEL 為 `iscsi-initiator-utils`） |

> **kubelet 路徑提醒**：驅動預設的部署 manifest 假設 kubelet root 目錄為 `/var/lib/kubelet`。本文件是以標準 `kubeadm` 建置（非 MicroK8s / K3s），kubelet 路徑本來就是這個預設值，因此**不需要**額外修改 manifest 中的 `hostPath`；若你日後改用 MicroK8s、K3s 等發行版，才需要依官方文件調整對應路徑。

### 12.2 節點前置作業

**（選用）若要使用 iSCSI，在全部 Worker 節點安裝並啟用 open-iscsi：**

```bash
sudo dnf install -y iscsi-initiator-utils
sudo systemctl enable --now iscsid
```

**在 TrueNAS 上準備 API Key：** 登入 TrueNAS 網頁介面 → 右上角個人資料 → API Keys → 建立一組新的 API Key 並複製保存，後續會存進 Kubernetes 的 Secret。

### 12.3（選用）安裝 Snapshot 支援套件

若需要用 VolumeSnapshot 做備份/還原，需先安裝 external-snapshotter 的 CRD 與 snapshot-controller：

```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotclasses.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshotcontents.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/client/config/crd/snapshot.storage.k8s.io_volumesnapshots.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/rbac-snapshot-controller.yaml
kubectl apply -f https://raw.githubusercontent.com/kubernetes-csi/external-snapshotter/master/deploy/kubernetes/snapshot-controller/setup-snapshot-controller.yaml
```

### 12.4 下載並設定部署 manifest

```bash
curl -O https://raw.githubusercontent.com/truenas/truenas-csi/master/deploy/truenas-csi-driver.yaml
```

編輯 `truenas-csi-driver.yaml`，主要調整兩個地方：

1. **ConfigMap**（TrueNAS 連線資訊）：

```yaml
# ConfigMap 內容示意，依實際 TrueNAS 環境調整
truenasURL: "wss://<TRUENAS_IP>/api/current"
truenasInsecure: "true"          # 若 TrueNAS 用自簽憑證
defaultPool: "tank"               # 預設 ZFS pool 名稱
nfsServer: "<TRUENAS_IP>"
iscsiPortal: "<TRUENAS_IP>:3260"  # 只有要用 iSCSI 才需要
iscsiIQNBase: "iqn.2005-10.org.freenas.ctl"
```

2. **Secret**（API Key）：把前面在 TrueNAS 上建立的 API Key 填入對應欄位。

> 若日後要在 GitOps / Git 版控中管理這份設定，建議把含有 API Key 的 Secret 從 manifest 拆開，改用 `kubectl create secret` 或 Sealed Secrets / External Secrets 等機制單獨管理，避免明碼寫入版控。

### 12.5 部署驅動程式並驗證

```bash
kubectl apply -f truenas-csi-driver.yaml
```

驗證安裝：

```bash
# 確認驅動 pod 皆為 Running（controller 1 份、每個節點各一個 node plugin）
kubectl get pods -n truenas-csi

# 確認 CSI 驅動已註冊到叢集
kubectl get csidrivers
```

### 12.6 建立 StorageClass 並測試 PVC（NFS 範例）

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-nfs
provisioner: csi.truenas.io
parameters:
  protocol: nfs
  pool: tank
  compression: "lz4"
  sync: "standard"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF
```

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-nfs-pvc
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: truenas-nfs
  resources:
    requests:
      storage: 5Gi
EOF

kubectl get pvc demo-nfs-pvc
```

掛載到一個測試 Pod 驗證讀寫：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: demo-nfs-pod
spec:
  containers:
  - name: app
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: data
      mountPath: /data
  volumes:
  - name: data
    persistentVolumeClaim:
      claimName: demo-nfs-pvc
EOF

kubectl exec demo-nfs-pod -- sh -c 'echo hello-truenas > /data/test.txt && cat /data/test.txt'
```

清除測試資源：

```bash
kubectl delete pod demo-nfs-pod
kubectl delete pvc demo-nfs-pvc
```

### 12.7（選用）iSCSI StorageClass 範例

```bash
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: truenas-iscsi
provisioner: csi.truenas.io
parameters:
  protocol: iscsi
  pool: tank
  volblocksize: "4K"
reclaimPolicy: Delete
allowVolumeExpansion: true
volumeBindingMode: Immediate
EOF
```

PVC 建立方式與 NFS 相同，只需把 `storageClassName` 換成 `truenas-iscsi`，`accessModes` 依需求用 `ReadWriteOnce`（一般情況）或 `ReadWriteMany`（節點需具備 GFS2/OCFS2 叢集檔案系統）。

### 12.8（選用）快照與 Clone

先建立 VolumeSnapshotClass：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshotClass
metadata:
  name: truenas-snapshot-class
driver: csi.truenas.io
deletionPolicy: Delete
EOF
```

對既有 PVC 建立快照：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: snapshot.storage.k8s.io/v1
kind: VolumeSnapshot
metadata:
  name: demo-nfs-snapshot
  namespace: default
spec:
  volumeSnapshotClassName: truenas-snapshot-class
  source:
    persistentVolumeClaimName: demo-nfs-pvc
EOF
```

用快照還原成新的 PVC（Clone）：

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: demo-nfs-restored
  namespace: default
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: truenas-nfs
  resources:
    requests:
      storage: 5Gi
  dataSource:
    name: demo-nfs-snapshot
    kind: VolumeSnapshot
    apiGroup: snapshot.storage.k8s.io
EOF
```

### 12.9 疑難排解

| 症狀 | 排查方向 |
|---|---|
| PVC 一直 `Pending` | `kubectl describe pvc <name>` 查看事件；確認 `truenas-csi` controller pod 是否 Running，以及 ConfigMap 中的 `truenasURL` / API Key 是否正確 |
| Pod 掛載 NFS 卷成功，但看到的內容是節點本地資料而非 TrueNAS 內容 | 通常是 kubelet 路徑與 manifest 中 `hostPath` 不一致造成 mount 未正確傳遞；標準 kubeadm 環境（本文件）預設不會發生，只有改用 MicroK8s/K3s 等非標準路徑發行版時才需留意 |
| iSCSI 卷無法連接 | 確認 Worker 節點已安裝並啟動 `iscsid`（`systemctl status iscsid`），且 TrueNAS 端的 iSCSI Portal / Target 設定與 `iscsiPortal` 一致 |
| VolumeSnapshot 一直沒有 `readyToUse: true` | 確認已依 12.3 安裝 external-snapshotter 的 CRD 與 snapshot-controller，並執行 `kubectl describe volumesnapshot <name>` 查看事件 |
| API 連線失敗（TLS 憑證錯誤） | 若 TrueNAS 使用自簽憑證，確認 ConfigMap 的 `truenasInsecure` 已設為 `"true"`；正式環境建議改用正式憑證，而非長期略過 TLS 驗證 |

---

## 13. 擴充 Control Plane 與 Worker 節點

### 13.1 擴充 Worker 節點

最單純的情境，跟最初加入 Worker 的步驟完全一樣。新節點請先完成本文件「1. 系統前置準備」「2. 安裝 CRI-O」「3. 安裝 kubeadm / kubelet / kubectl」三個章節，再執行加入指令。

```bash
# 在 CP 上重新產生 join 指令（token 預設 24 小時過期）
kubeadm token create --print-join-command
```

```bash
# 在新 Worker 上執行（換成上面指令實際輸出的 token / hash）
sudo kubeadm join 10.0.1.10:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --cri-socket=unix:///var/run/crio/crio.sock
```

加入後在 CP 確認：

```bash
kubectl get nodes -o wide
kubectl -n calico-system get pods -o wide
```

新節點會自動出現 Calico 的 `calico-node` pod，待其 Running 後節點即轉為 `Ready`。

### 13.2 擴充 Control Plane 節點（HA）

> **重要提醒**：本文件最初的 `kubeadm init` 是以單一 CP 規劃，並未指定 `--control-plane-endpoint`（穩定的負載平衡入口，如 VIP 或 LB DNS）。**若要擴充成多 CP 高可用架構，強烈建議在規劃階段就先用 `--control-plane-endpoint` 重新建置叢集**，而不是事後在既有單 CP 叢集上硬加節點 —— 否則所有節點上 kubeconfig 內的 API Server 位址都還是指向第一台 CP 的單一 IP，原 CP 故障時其他元件仍會連不到叢集。

以下分兩種情境說明：

#### A. 尚未建置（建議路徑）：規劃階段就採用 LB / VIP

1. 先準備好一個負載平衡入口（例如 keepalived VIP、HAProxy，或雲端 LB），假設為 `10.0.1.100:6443`，並把流量導向所有未來的 CP 節點 6443 埠。
2. 第一台 CP 初始化時加上 `--control-plane-endpoint` 與 `--upload-certs`：

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --control-plane-endpoint="10.0.1.100:6443" \
  --upload-certs \
  --cri-socket=unix:///var/run/crio/crio.sock \
  --kubernetes-version=v1.36.2
```

3. 輸出會同時提供兩種 join 指令：一種帶 `--control-plane`（給其他 CP 用），一種不帶（給 Worker 用）。其中 CP 用的指令會包含 `--certificate-key`（預設 2 小時內有效）。
4. 在新的 CP 節點上（先完成章節 1~3 前置作業），執行對應指令：

```bash
sudo kubeadm join 10.0.1.100:6443 \
  --token <TOKEN> \
  --discovery-token-ca-cert-hash sha256:<HASH> \
  --control-plane \
  --certificate-key <CERTIFICATE_KEY> \
  --cri-socket=unix:///var/run/crio/crio.sock
```

5. 完成後設定該節點的 kubectl，並確認：

```bash
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

kubectl get nodes -o wide
```

CP 節點應為奇數（1、3、5...），以維持 etcd 多數決機制；本文件範例若擴充為 3 台 CP，建議規劃為 1 → 3，不建議停在 2 台。

`--certificate-key` 過期後，可在既有 CP 重新產生：

```bash
sudo kubeadm init phase upload-certs --upload-certs
```

#### B. 已經是單 CP 在跑（補救路徑）

若叢集已用本文件原本的方式（無 `--control-plane-endpoint`）建置完成，要加入更多 CP 前需要先補上穩定入口：

1. 建立 LB / VIP，導向現有 CP（先單台）的 6443。
2. 修改叢集內 `kubeadm-config` ConfigMap 中的 `controlPlaneEndpoint`，並重新簽發 API Server 憑證以包含新的 LB 位址 / VIP 的 SAN：

```bash
kubectl -n kube-system edit cm kubeadm-config
# 將 ClusterConfiguration.controlPlaneEndpoint 設成 "10.0.1.100:6443"
```

```bash
# 在現有 CP 上重新產生包含新 SAN 的憑證（務必先備份 /etc/kubernetes/pki）
sudo cp -a /etc/kubernetes/pki /etc/kubernetes/pki.backup.$(date +%Y%m%d%H%M%S)
sudo mv /etc/kubernetes/pki/apiserver.crt /etc/kubernetes/pki/apiserver.crt.bak
sudo mv /etc/kubernetes/pki/apiserver.key /etc/kubernetes/pki/apiserver.key.bak
sudo kubeadm init phase certs apiserver --control-plane-endpoint "10.0.1.100:6443"
sudo systemctl restart kubelet
```

3. 確認新憑證生效、所有現有節點上的 kubeconfig（`/etc/kubernetes/*.conf`、`$HOME/.kube/config`）改指向新的 LB 位址後，再依照「A. 規劃階段」第 3 步開始的流程加入新的 CP 節點。

> 此補救路徑涉及憑證重簽與既有元件設定異動，風險較高，建議先在測試環境演練過、並完成 etcd 備份後再於正式環境操作。若條件允許，更穩妥的做法是直接以方案 A 重新建置一座新叢集，再把工作負載遷移過去。

### 13.3 etcd 備份提醒

擴充或變更 CP 拓樸前，務必先備份 etcd：

```bash
sudo ETCDCTL_API=3 etcdctl snapshot save /root/etcd-backup-$(date +%Y%m%d%H%M).db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

---

## 14. 常見問題排查

| 症狀 | 排查方向 |
|---|---|
| 節點長時間 `NotReady` | 檢查 `kubectl -n calico-system logs ds/calico-node`，確認 br_netfilter / sysctl 是否生效 |
| `crictl` 連不到 runtime | 確認 `crio` 服務狀態，以及 `crictl` 設定檔 `/etc/crictl.yaml` 的 `runtime-endpoint` 是否指向 `unix:///var/run/crio/crio.sock` |
| kubeadm join token 過期 | 在 CP 執行 `kubeadm token create --print-join-command` 重新產生 |
| SELinux 導致 Pod 啟動失敗 | 暫時 `setenforce 0` 測試是否為 SELinux 阻擋，再決定後續是否撰寫對應 policy |
| 跨節點 Pod 無法互通 | 確認所有節點 `4789/udp`（VXLAN）已開放，且 firewalld 的 zone 設定沒有擋住 Calico 建立的網卡（如 `vxlan.calico`） |
| `tigerastatus/calico` 一直未 Available | `kubectl get tigerastatus calico -o yaml` 查看詳細錯誤，常見原因是 `custom-resources.yaml` 的 CIDR 與 `--pod-network-cidr` 不一致 |
| `--certificate-key` 過期，無法加入新 CP | 在既有 CP 執行 `sudo kubeadm init phase upload-certs --upload-certs` 重新產生 |

---

## 15. 版本資訊備查

* Kubernetes：v1.36（最新穩定版 1.36.2，2026-06-09 釋出，EOL 2027-06-28）
* CRI-O：對齊 Kubernetes minor 版本，本文使用 v1.36 系列
* Calico：v3.32.1（以 Tigera Operator 安裝；K8s 1.36 已 GA 啟用 `MutatingAdmissionPolicy`，無需額外開 feature gate）
* MetalLB：v0.16.1（manifest 安裝，Layer2 模式）
* KubeVirt：v1.8.4（官方對齊 K8s v1.35，並額外支援前兩版；本文件叢集為 v1.36，屬超出官方正式驗證範圍但通常可運作的組合，導入前請留意 support matrix）
* Gateway API：v1.6.0（Standard channel CRDs）+ Calico Ingress Gateway（隨 Calico v3.32.1 內建的 Envoy Gateway 發行版，經 Tigera Operator 管理）
* TrueNAS CSI：truenas/truenas-csi（master 分支部署 manifest；需搭配 TrueNAS SCALE 25.10.0 以上、K8s 1.26 以上）

> 套件版本會持續更新，正式環境建議在套用前至官方頁面（kubernetes.io/releases、cri-o 官方 repo、Calico Releases / docs.tigera.io、MetalLB Installation / GitHub Releases、KubeVirt Releases / support matrix、Gateway API Releases / gateway-api.sigs.k8s.io、TrueNAS CSI GitHub Releases）再次確認當下最新的 patch 版本號與相容性。
