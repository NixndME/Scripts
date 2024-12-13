#!/bin/bash
set -e

# Variable
VIP_ADDRESS="172.20.20.88"
CLUSTER_CIDR="172.20.0.0/16"
SERVICE_CIDR="172.20.20.0/24"
K3S_TOKEN="${K3S_TOKEN:-$(head -c 16 /dev/urandom | od -An -t x | tr -d ' ')}"
CALICO_VERSION="v3.27.2"
KUBEVIP_VERSION="v0.7.1"

hostname=$(hostname)
echo "Starting installation on $hostname with VIP: $VIP_ADDRESS"
worker=0

# functions
create_dirs_safely() {
    local dir=$1
    local owner=$2
    sudo mkdir -p "$dir"
    sudo chown "$owner:$owner" "$dir"
    sudo chmod 750 "$dir"
}

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

setup_vip() {
    create_dirs_safely "/var/lib/rancher/k3s/server/manifests" "root"
    curl -sfL https://kube-vip.io/manifests/rbac.yaml > /var/lib/rancher/k3s/server/manifests/kube-vip-rbac.yaml

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
        --address "$VIP_ADDRESS" \
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

configure_primary_master() {
    setup_vip

    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -s - server \
        --cluster-init \
        --tls-san="$VIP_ADDRESS" \
        --tls-san="<%=cluster.masters[0].internalIp%>" \
        --node-external-ip="<%=node.internalIp%>" \
        --advertise-address="<%=node.internalIp%>" \
        --bind-address="<%=node.internalIp%>" \
        --node-ip="<%=node.internalIp%>" \
        --disable servicelb \
        --flannel-backend=none \
        --disable-network-policy \
        --cluster-cidr="$CLUSTER_CIDR" \
        --service-cidr="$SERVICE_CIDR" \
        --write-kubeconfig-mode 640

    setup_calico

   
    create_dirs_safely "<%=morpheus.morpheusHome%>/kube" "<%=morpheus.morpheusUser%>"
    create_dirs_safely "<%=morpheus.morpheusHome%>/.kube" "<%=morpheus.morpheusUser%>"
    create_dirs_safely "/etc/kubernetes" "root"
    create_dirs_safely "/root/.kube" "root"


    for config in \
        "<%=morpheus.morpheusHome%>/.kube/config:<%=morpheus.morpheusUser%>:600" \
        "/etc/kubernetes/admin.conf:<%=morpheus.morpheusUser%>:600" \
        "/root/.kube/config:root:400"
    do
        IFS=: read -r path owner perms <<< "$config"
        sudo cp -f /etc/rancher/k3s/k3s.yaml "$path"
        sudo chown "$owner:$owner" "$path"
        sudo chmod "$perms" "$path"
        sudo sed -i "s/127.0.0.1/$VIP_ADDRESS/" "$path"
    done

    for sa_cmd in \
        "kubectl create sa morpheus" \
        "kubectl create clusterrolebinding serviceaccounts-cluster-admin --clusterrole=cluster-admin --group=system:serviceaccounts"
    do
        for i in {1..3}; do
            if $sa_cmd; then
                break
            fi
            echo "Retrying: $sa_cmd"
            sleep 5
        done
    done


    if ! command -v helm &> /dev/null; then
        curl -sfL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | sudo bash
    fi
}

configure_secondary_master() {
    if ! wait_for_api "https://$VIP_ADDRESS:6443/healthz"; then
        exit 1
    fi

    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -s - server \
        --server "https://$VIP_ADDRESS:6443" \
        --tls-san="$VIP_ADDRESS" \
        --node-external-ip="<%=node.internalIp%>" \
        --node-ip="<%=node.internalIp%>" \
        --disable servicelb \
        --flannel-backend=none \
        --disable-network-policy \
        --write-kubeconfig-mode 640
}

configure_worker() {
    if ! wait_for_api "https://$VIP_ADDRESS:6443/healthz"; then
        exit 1
    fi

    curl -sfL https://get.k3s.io | \
        INSTALL_K3S_VERSION="<%=customOptions.k3sversion%>" \
        K3S_TOKEN="$K3S_TOKEN" \
        sh -s - agent \
        --server "https://$VIP_ADDRESS:6443" \
        --node-ip="<%=node.internalIp%>"
}


if [ $hostname = "<%=cluster.masters[0].hostname%>" ]; then
    echo "Configuring Primary Master"
    worker=1
    configure_primary_master
elif [[ "$hostname" == *"master"* ]]; then
    echo "Configuring Secondary Master"
    worker=1
    configure_secondary_master
else
    echo "Configuring Worker Node"
    configure_worker
fi

echo "Installation completed successfully on $hostname"
