
# Prerequisites


- 4 Ubuntu machines on Proxmox with IP addresses:
    - Master-01: 192.168.1.30/24
    - Master-02: 192.168.1.72/24
    - Master-03: 192.168.1.26/24
    - Worker-01: 192.168.1.51/24

# Step-by-Step Kubernetes Cluster Installation

## 1. Preparation (Run on ALL nodes)

First, let's prepare all the nodes with common configurations:

```bash
# Update all packages
sudo apt-get update
sudo apt-get upgrade -y

# Install required packages
sudo apt-get install -y apt-transport-https ca-certificates curl software-properties-common

# Disable swap (required for Kubernetes)
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

# Load necessary modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

sudo modprobe overlay
sudo modprobe br_netfilter

# Set up necessary sysctl parameters
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

# Apply sysctl parameters without reboot
sudo sysctl --system

# Install containerd runtime
sudo apt-get update
sudo apt-get install -y containerd

# Configure containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml

# Edit containerd config to use systemd cgroup driver
sudo sed -i 's/SystemdCgroup \= false/SystemdCgroup \= true/g' /etc/containerd/config.toml

# Restart containerd
sudo systemctl restart containerd
sudo systemctl enable containerd

# Add Kubernetes repository
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.30/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.30/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

# Update apt and install kubeadm, kubelet and kubectl
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Configure /etc/hosts to include all nodes
sudo tee -a /etc/hosts <<EOF
192.168.1.30 master-01
192.168.1.72 master-02
192.168.1.26 master-03
192.168.1.51 worker-01
EOF
```

## 2. Initialize the First Master Node (Run on Master-01 only)

```bash
# Create kubeadm config file for HA setup
cat <<EOF > kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v1.30.0
controlPlaneEndpoint: "master-01:6443"
networking:
  podSubnet: "10.244.0.0/16"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF

# Initialize the first control plane
sudo kubeadm init --config=kubeadm-config.yaml --upload-certs

# After successful initialization, you'll see output with a token and certificate key
# Save this information as you'll need it to join other master and worker nodes
# It will look something like:
# kubeadm join master-01:6443 --token <token> --discovery-token-ca-cert-hash <hash> --control-plane --certificate-key <certificate-key>
# for master nodes and
# kubeadm join master-01:6443 --token <token> --discovery-token-ca-cert-hash <hash>
# for worker nodes

# Set up kubectl for the current user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Install a CNI plugin (Calico)
kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml
```

## 3. Join the Other Master Nodes (Run on Master-02 and Master-03)

Use the join command you received from the kubeadm init output on Master-01:

```bash
# Example (replace with your actual values)
sudo kubeadm join master-01:6443 --token <token> \
    --discovery-token-ca-cert-hash <hash> \
    --control-plane --certificate-key <certificate-key>

# After joining, set up kubectl for the current user
mkdir -p $HOME/.kube
sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config
```

## 4. Join the Worker Node (Run on Worker-01)

Use the worker join command from the kubeadm init output:

```bash
# Example (replace with your actual values)
sudo kubeadm join master-01:6443 --token <token> \
    --discovery-token-ca-cert-hash <hash>
```

## 5. Verify the Cluster (Run on any master node)

```bash
# Check node status
kubectl get nodes

# Check pods across all namespaces
kubectl get pods --all-namespaces
```

## 6. Adding New Nodes Later

### To add a new master node later:

1. Prepare the new node with all steps from Section 1.
2. Generate a new certificate key and token (if the old ones expired) on an existing master:

```bash
# Generate a new certificate key
sudo kubeadm init phase upload-certs --upload-certs

# Create a new token
kubeadm token create --print-join-command
```

3. Join the new master with the new certificate key and token:

```bash
sudo kubeadm join master-01:6443 --token <new-token> \
    --discovery-token-ca-cert-hash <hash> \
    --control-plane --certificate-key <new-certificate-key>
```

### To add a new worker node later:

1. Prepare the new node with all steps from Section 1.
2. Create a new token if the old one expired:

```bash
# On a master node, create a new token
kubeadm token create --print-join-command
```

3. Join the new worker with the token:

```bash
sudo kubeadm join master-01:6443 --token <new-token> \
    --discovery-token-ca-cert-hash <hash>
```

## Troubleshooting Tips

1. If nodes don't join, check firewall rules to ensure ports are open:
    
    - TCP 6443: Kubernetes API server
    - TCP 2379-2380: etcd server client API
    - TCP 10250: Kubelet API
    - TCP 10251: kube-scheduler
    - TCP 10252: kube-controller-manager
2. Check logs for errors:
    
    ```bash
    sudo journalctl -xeu kubelet
    ```
    
3. If a node is stuck in NotReady state, check CNI plugin installation:
    
    ```bash
    kubectl get pods -n kube-system
    ```

