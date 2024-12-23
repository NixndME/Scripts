#!/bin/bash
set -x  # Exit on error

K3S_TOKEN="66a02720595974d16391fe42bf72abfd"
CALICO_VERSION="v3.27.2"
KUBEVIP_VERSION="v0.7.1"

hostname=$(hostname)
echo "Starting installation on $hostname"
worker=0

# Function to wait for k3s to be ready
wait_for_k3s() {
    echo "Waiting for k3s to be ready..."
    timeout=180
    while [ $timeout -gt 0 ] && ! kubectl get nodes >/dev/null 2>&1; do
        echo "Waiting for k3s... ${timeout}s remaining"
        sleep 5
        timeout=$((timeout - 5))
    done
    [ $timeout -gt 0 ] || (echo "k3s timeout" && exit 1)
}

wait_for_api() {
    local api_endpoint=$1
    echo "Waiting for API endpoint: $api_endpoint"
    timeout=180
    while [ $timeout -gt 0 ]; do
        if curl -skf "$api_endpoint" >/dev/null 2>&1; then
            echo "API endpoint is accessible"
            return 0
        fi
        echo "Waiting for API... ${timeout}s remaining"
        sleep 5
        timeout=$((timeout - 5))
    done
    echo "API endpoint timeout"
    return 1
}

create_dirs_safely() {
    local dir=$1
    local owner=$2
    sudo mkdir -p "$dir"
    sudo chown "$owner:$owner" "$dir"
    sudo chmod 750 "$dir"
}

setup_vip() {
    create_dirs_safely "/var/lib/rancher/k3s/server/manifests" "root"
    curl -sfL https://kube-vip.io/manifests/rbac.yaml > /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml
    kubectl create -f /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml

    echo "Waiting for containerd..."
    timeout=60
    while [ $timeout -gt 0 ] && ! ctr version >/dev/null 2>&1; do
        sleep 2
        timeout=$((timeout - 2))
    done
    [ $timeout -gt 0 ] || (echo "containerd timeout" && exit 1)

    ctr image pull ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION}
    ctr run --rm --net-host ghcr.io/kube-vip/kube-vip:${KUBEVIP_VERSION} vip /kube-vip manifest daemonset \
        --interface eth0 \
        --address "<%=customOptions.k3svipaddress%>" \
        --inCluster \
        --taint \
        --controlplane \
        --services \
        --arp \
        --leaderElection > /var/lib/rancher/k3s/server/manifests/kube-vip.yaml
}

setup_calico() {
    wait_for_k3s

    for i in {1..3}; do
        if kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/tigera-operator.yaml; then
            echo "Calico operator installed successfully"
            break
        fi
        echo "Retrying Calico operator installation... Attempt $i/3"
        sleep 10
    done

    for i in {1..3}; do
        if kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/custom-resources.yaml; then
            echo "Calico resources installed successfully"
            break
        fi
        echo "Retrying Calico resources installation... Attempt $i/3"
        sleep 10
    done
}

configure_primary_master_calico() {
    echo "Installing K3s"
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN=${K3S_TOKEN} \
        sh -s - server \
        --cluster-init \
        --tls-san="<%=customOptions.k3svipaddress%>" \
        --disable servicelb \
        --flannel-backend=none \
        --disable-network-policy \
        --cluster-cidr="<%=customOptions.k3sclustercidr%>" \
        --service-cidr="<%=customOptions.k3sservicecidr%>" \
        --write-kubeconfig-mode 644
        
    echo "Setting up calico"
    setup_calico

    echo "Setting up VIP"
    setup_vip
    
    echo "Setting up Morpheus configurations"
    create_dirs_safely "<%=morpheus.morpheusHome%>/kube" "<%=morpheus.morpheusUser%>"
    create_dirs_safely "<%=morpheus.morpheusHome%>/.kube" "<%=morpheus.morpheusUser%>"
    create_dirs_safely "/etc/kubernetes" "root"
    create_dirs_safely "/root/.kube" "root"

    echo "Copying kubeconfig files"
    for config in \
        "<%=morpheus.morpheusHome%>/.kube/config:<%=morpheus.morpheusUser%>:600" \
        "/etc/kubernetes/admin.conf:<%=morpheus.morpheusUser%>:600" \
        "/root/.kube/config:root:400"
    do
        IFS=: read -r path owner perms <<< "$config"
        sudo cp -f /etc/rancher/k3s/k3s.yaml "$path"
        sudo chown "$owner:$owner" "$path"
        sudo chmod "$perms" "$path"
        sudo sed -i "s/127.0.0.1/<%=customOptions.k3svipaddress%>/" "$path"
    done

    echo "Setting up a service account and its secret"
    for sa_cmd in \
        "kubectl create sa morpheus" \
        "kubectl create clusterrolebinding serviceaccounts-cluster-admin --clusterrole=cluster-admin --group=system:serviceaccounts" \
        "kubectl create -f <%=morpheus.morpheusHome%>/morpheus-sa.yaml"
    do
        for i in {1..3}; do
            if $sa_cmd; then
                break
            fi
            echo "Retrying: $sa_cmd"
            sleep 5
        done
    done

    echo "Installing Helm"
    if ! command -v helm &> /dev/null; then
        curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
    fi
}

configure_secondary_master() {
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN=${K3S_TOKEN} \
        sh -s - server \
        --server https://<%=customOptions.k3svipaddress%>:6443 \
        --tls-san="<%=customOptions.k3svipaddress%>" \
        --disable servicelb \
        --flannel-backend=none \
        --disable-network-policy \
        --cluster-cidr="<%=customOptions.k3sclustercidr%>" \
        --service-cidr="<%=customOptions.k3sservicecidr%>"
}

configure_worker() {
    echo "Setting up Worker Node using VIP"
    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN=${K3S_TOKEN} \
        sh -s - agent \
        --server https://<%=customOptions.k3svipaddress%>:6443
    echo "Finished Worker Nodes"
}

if [ $hostname = "<%=cluster.masters[0].hostname%>" ]; then
    echo "Installing and Configuring Primary Master"
    worker=1
 
    case "<%=customOptions.k3snetworking%>" in
        flannel)
            echo "Installing with flannel networking"
            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN=${K3S_TOKEN} \
                sh -s - server \
                --write-kubeconfig-mode 640 \
                --cluster-init \
                --tls-san="<%=cluster.masters[0].internalIp%>" \
                --disable servicelb
            ;;
        
        calico)                       
            echo "Installing with calico networking"
            configure_primary_master_calico
            ;;
        
        cilium)
            echo "Installing with cilium networking"
            curl -sfL https://get.k3s.io | \
                INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
                K3S_TOKEN=${K3S_TOKEN} \
                sh -s - server \
                --write-kubeconfig-mode 644 \
                --cluster-init \
                --tls-san="<%=cluster.masters[0].internalIp%>" \
                --disable servicelb \
                --flannel-backend=none

            # Wait for k3s to be ready before setting up Cilium
            wait_for_k3s
            
            sudo mount bpffs -t bpf /sys/fs/bpf
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
    
    echo "Finished Primary Master Bootstrap"
    
elif [[ "$hostname" == *"master"* ]]; then
    echo "Installing and Configuring Secondary Master"
    worker=1
    configure_secondary_master

    echo "Finished Secondary Master"
fi 

if [ $worker -eq 0 ]; then
    echo "Configuring Worker Node using VIP"
    configure_worker
    echo "Finished Worker Node" 
fi

echo "Installation completed on $hostname"
