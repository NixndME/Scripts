#!/bin/bash
set -e  # Exit on error

# Generate a secure token if not provided
if [ -z "$K3S_TOKEN" ]; then
    K3S_TOKEN=$(head -c 16 /dev/urandom | od -An -t x | tr -d ' ')
fi

hostname=$(hostname)
echo "Starting installation on $hostname"
worker=0

# Enhanced wait function
wait_for_k3s() {
    echo "Waiting for k3s to be ready..."
    timeout=120  # 2 minutes timeout
    counter=0
    while [ $counter -lt $timeout ] && ! kubectl get nodes >/dev/null 2>&1; do
        echo "Still waiting... $(($timeout - $counter)) seconds remaining"
        sleep 2
        counter=$((counter + 1))
    done
    if [ $counter -eq $timeout ]; then
        echo "Timeout waiting for k3s"
        exit 1
    fi
}

# Function to create directories safely
create_dirs_safely() {
    local dir=$1
    local owner=$2
    sudo mkdir -p "$dir"
    sudo chown "$owner:$owner" "$dir"
    sudo chmod 750 "$dir"
}

if [ $hostname = "<%=cluster.masters[0].hostname%>" ]; then
    echo "Initial Master"
    worker=1
    
    case "<%=customOptions.k3snetworking%>" in
        flannel)
            echo "Installing with flannel networking"
            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN="$K3S_TOKEN" \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --cluster-init \
                --tls-san="<%=cluster.masters[0].internalIp%>" \
                --disable servicelb
            ;;
        
        calico)
            echo "Installing with calico networking"
            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN="$K3S_TOKEN" \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --cluster-init \
                --tls-san="<%=cluster.masters[0].internalIp%>" \
                --disable servicelb \
                --flannel-backend=none \
                --disable-network-policy \
                --cluster-cidr=192.168.0.0/16

            # Wait for k3s to be ready before applying Calico
            wait_for_k3s
            
            # Apply Calico manifests with retries
            for i in {1..3}; do
                if kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/tigera-operator.yaml; then
                    break
                fi
                echo "Retrying Calico operator installation..."
                sleep 10
            done

            for i in {1..3}; do
                if kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.2/manifests/custom-resources.yaml; then
                    break
                fi
                echo "Retrying Calico resources installation..."
                sleep 10
            done
            ;;
        
        cilium)
            echo "Installing with cilium networking"
            # Ensure BPF filesystem is mounted
            if ! mount | grep -q "bpf on /sys/fs/bpf type bpf"; then
                sudo mount bpffs -t bpf /sys/fs/bpf
            fi

            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN="$K3S_TOKEN" \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --cluster-init \
                --tls-san="<%=cluster.masters[0].internalIp%>" \
                --disable servicelb \
                --flannel-backend=none

            # Wait for k3s to be ready before setting up Cilium
            wait_for_k3s
            
            # Install Cilium CLI
            CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
            CLI_ARCH=amd64
            if [ "$(uname -m)" = "aarch64" ]; then CLI_ARCH=arm64; fi
            curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
            sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
            sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin
            rm cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
            export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
            cilium install
            ;;
    esac

    # Wait for k3s configuration
    echo "Waiting for k3s configuration..."
    timeout=60
    while [ ! -f /etc/rancher/k3s/k3s.yaml ] && [ $timeout -gt 0 ]; do
        sleep 2
        timeout=$((timeout - 2))
    done

    if [ ! -f /etc/rancher/k3s/k3s.yaml ]; then
        echo "Timeout waiting for k3s configuration"
        exit 1
    fi

    # Morpheus Setup
    echo "Setting up Morpheus configurations"
    create_dirs_safely "<%=morpheus.morpheusHome%>/kube" "<%=morpheus.morpheusUser%>"
    create_dirs_safely "<%=morpheus.morpheusHome%>/.kube" "<%=morpheus.morpheusUser%>"
    create_dirs_safely "/etc/kubernetes" "root"

    # Copy and secure kubeconfig files
    sudo cp -f /etc/rancher/k3s/k3s.yaml "<%=morpheus.morpheusHome%>/.kube/config"
    sudo chown "<%=morpheus.morpheusUser%>:<%=morpheus.morpheusUser%>" "<%=morpheus.morpheusHome%>/.kube/config"
    sudo chmod 600 "<%=morpheus.morpheusHome%>/.kube/config"
    
    sudo cp -f /etc/rancher/k3s/k3s.yaml /etc/kubernetes/admin.conf
    sudo chown "<%=morpheus.morpheusUser%>:<%=morpheus.morpheusUser%>" /etc/kubernetes/admin.conf
    sudo chmod 600 /etc/kubernetes/admin.conf

    # Set up service account with retries
    for i in {1..3}; do
        if kubectl create sa morpheus; then
            break
        fi
        sleep 5
    done

    for i in {1..3}; do
        if kubectl create clusterrolebinding serviceaccounts-cluster-admin \
            --clusterrole=cluster-admin \
            --group=system:serviceaccounts; then
            break
        fi
        sleep 5
    done

    # Set up Helm
    if ! command -v helm &> /dev/null; then
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
    fi
    
    create_dirs_safely "/root/.kube" "root"
    sudo cp -f /etc/rancher/k3s/k3s.yaml /root/.kube/config
    sudo chmod 400 /root/.kube/config

    # Set up kube-vip
    echo "Setting up kube-vip"
    create_dirs_safely "/var/lib/rancher/k3s/server/manifests" "root"
    curl https://kube-vip.io/manifests/rbac.yaml > /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml
    
    # Wait for containerd
    echo "Waiting for containerd..."
    timeout=60
    while [ $timeout -gt 0 ] && ! ctr version >/dev/null 2>&1; do
        sleep 2
        timeout=$((timeout - 2))
    done

    if ! ctr version >/dev/null 2>&1; then
        echo "Timeout waiting for containerd"
        exit 1
    fi

    # Pull and run kube-vip
    ctr image pull ghcr.io/kube-vip/kube-vip:v0.7.1
    
    ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:v0.7.1 vip /kube-vip manifest daemonset \
        --interface eth0 \
        --address "<%=customOptions.k3svipaddress%>" \
        --inCluster \
        --taint \
        --controlplane \
        --arp \
        --leaderElection > /var/lib/rancher/k3s/server/manifests/kube-vip.yaml

elif [[ "$hostname" == *"master"* ]]; then
    echo "Secondary Master"
    worker=1
    
    # Wait for primary master
    echo "Waiting for primary master to be ready..."
    timeout=180  # 3 minutes timeout
    counter=0
    while [ $counter -lt $timeout ]; do
        if curl -k https://<%=cluster.masters[0].internalIp%>:6443/healthz >/dev/null 2>&1; then
            break
        fi
        echo "Still waiting... $(($timeout - $counter)) seconds remaining"
        sleep 2
        counter=$((counter + 1))
    done

    if [ $counter -eq $timeout ]; then
        echo "Timeout waiting for primary master"
        exit 1
    fi

    case "<%=customOptions.k3snetworking%>" in
        flannel)
            echo "Installing with flannel networking"
            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN="$K3S_TOKEN" \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --server https://<%=cluster.masters[0].internalIp%>:6443
            ;;
            
        calico)
            echo "Installing with calico networking"
            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN="$K3S_TOKEN" \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --server https://<%=cluster.masters[0].internalIp%>:6443 \
                --tls-san="<%=cluster.masters[0].internalIp%>" \
                --disable servicelb \
                --flannel-backend=none \
                --disable-network-policy
            ;;
            
        cilium)
            echo "Installing with cilium networking"
            # Ensure BPF filesystem is mounted
            if ! mount | grep -q "bpf on /sys/fs/bpf type bpf"; then
                sudo mount bpffs -t bpf /sys/fs/bpf
            fi

            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN="$K3S_TOKEN" \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --server https://<%=cluster.masters[0].internalIp%>:6443
            ;;
    esac
fi 

if [ $worker -eq 0 ]; then
    echo "Setting up Worker Node"
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -s - agent \
        --server https://<%=cluster.masters[0].internalIp%>:6443
fi

echo "Installation completed on $hostname"
