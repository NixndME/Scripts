#!/bin/bash
set -eo pipefail

# Variables
K8S_VERSION="1.30"
SCRIPT_NAME=$(basename "$0")
LOG_FILE="/var/log/k8s_setup_$(date '+%Y%m%d_%H%M%S')_$$.log"
SUMMARY_FILE="/tmp/k8s_setup_summary_$(date '+%Y%m%d_%H%M%S')_$$.txt"
NODE_TYPE=""
NODE_IP=""
MASTER_IP=""
CONTROL_PLANE_HOSTNAME="master-01"
FIRST_RUN="false"
ARCHITECTURE=$(dpkg --print-architecture 2>/dev/null) || ARCHITECTURE="amd64"
CUSTOM_HOSTNAME=""
IP_REGEX='^([0-9]{1,3}\.){3}[0-9]{1,3}$'

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    echo -e "${RED}Error: This script must be run as root or with sudo privileges${NC}" >&2
    exit 1
fi

# Create log directory
mkdir -p "$(dirname "$LOG_FILE")" || { echo -e "${RED}Failed to create log directory $(dirname "$LOG_FILE")${NC}" >&2; exit 1; }

# Logging function
log() {
    local level="$1"
    local message="$2"
    local color="${NC}"
    case "$level" in
        "INFO") color="${BLUE}" ;;
        "SUCCESS") color="${GREEN}" ;;
        "WARNING") color="${YELLOW}" ;;
        "ERROR") color="${RED}" ;;
        *) color="${NC}" ;;
    esac
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${color}[${timestamp}] [${level}] ${message}${NC}"
    echo "[${timestamp}] [${level}] ${message}" >> "$LOG_FILE"
}

# Add to summary function
add_to_summary() {
    local status="$1"
    local message="$2"
    local icon=""
    case "$status" in
        "DONE") icon="✅" ;;
        "SKIPPED") icon="⏭️" ;;
        "FAILED") icon="❌" ;;
        "INFO") icon="ℹ️" ;;
        *) icon="🔹" ;;
    esac
    echo "${icon} ${message}" >> "$SUMMARY_FILE"
}

# Detect primary IP function
detect_primary_ip() {
    local detected_ip
    if command -v ip &> /dev/null; then
        detected_ip=$(ip -4 route get 8.8.8.8 2>/dev/null | grep -oP 'src \K[0-9.]+' | head -1)
    elif command -v hostname &> /dev/null; then
        detected_ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    elif command -v ifconfig &> /dev/null; then
        detected_ip=$(ifconfig | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1' | head -1)
    fi
    if [[ -n "$detected_ip" && "$detected_ip" =~ $IP_REGEX ]]; then
        echo "$detected_ip"
        return 0
    fi
    return 1
}

# Find non-root user function
find_non_root_user() {
    local user
    user=$(grep "/home/" /etc/passwd | grep -v "nologin" | head -1 | cut -d: -f1)
    if [ -n "$user" ]; then
        echo "$user"
        return 0
    fi
    echo ""
    return 1
}

# Show help function
show_help() {
    cat << EOF
Usage: sudo $SCRIPT_NAME [OPTIONS]

This script sets up a Kubernetes $K8S_VERSION node with proper error handling and idempotence.
It configures prerequisites, installs Kubernetes components, and can initialize the first master.

OPTIONS:
  -h, --help              Show this help message and exit
  -t, --type TYPE         Specify node type: master or worker (required)
  -i, --ip IP_ADDRESS     Specify this node's primary IP address (optional, auto-detected if not provided)
  -f, --first-master      Designate this node as the first master node and run 'kubeadm init'
  -m, --master-ip IP      IP address of the first master node (control plane endpoint IP)
  -n, --hostname NAME     Specify custom hostname for this node (optional)

EXAMPLES:
  # Setup the first master node with auto-detected IP
  sudo $SCRIPT_NAME --type master --first-master

  # Setup the first master node with specific IP
  sudo $SCRIPT_NAME --type master --ip 192.168.1.10 --first-master

  # Setup additional master nodes
  sudo $SCRIPT_NAME --type master --master-ip 192.168.1.10

  # Setup worker nodes
  sudo $SCRIPT_NAME --type worker --master-ip 192.168.1.10
EOF
    exit 0
}

# Backup file function
backup_file() {
    local file_path="$1"
    if [ -f "$file_path" ]; then
        local backup_path="${file_path}.$(date '+%Y%m%d%H%M%S').bkp"
        log "INFO" "Backing up $file_path to $backup_path"
        if cp -p "$file_path" "$backup_path"; then
            log "SUCCESS" "Backup of $file_path created at $backup_path"
            return 0
        else
            log "ERROR" "Failed to backup $file_path"
            add_to_summary "FAILED" "Backup of $file_path"
            return 1
        fi
    fi
    log "INFO" "No existing file to backup at $file_path"
    return 0
}

# Check if command exists
command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Check if service is enabled
service_enabled() {
    systemctl is-enabled --quiet "$1"
}

# Check if service is running
service_running() {
    systemctl is-active --quiet "$1"
}

# Set hostname if needed
set_hostname_if_needed() {
    local desired_hostname="$1"
    local current_hostname=$(hostname)
    if [ "$current_hostname" != "$desired_hostname" ]; then
        log "INFO" "Setting hostname to $desired_hostname"
        if hostnamectl set-hostname "$desired_hostname"; then
            if grep -q "^127.0.1.1" /etc/hosts; then
                sed -i "s/^127.0.1.1.*/127.0.1.1 $desired_hostname/g" /etc/hosts
            else
                echo "127.0.1.1 $desired_hostname" >> /etc/hosts
            fi
            log "SUCCESS" "Hostname set to $desired_hostname"
            add_to_summary "DONE" "Set hostname to $desired_hostname"
        else
            log "ERROR" "Failed to set hostname to $desired_hostname"
            add_to_summary "FAILED" "Setting hostname to $desired_hostname"
            exit 1
        fi
    else
        log "INFO" "Hostname already set to $desired_hostname"
        add_to_summary "SKIPPED" "Hostname already set to $desired_hostname"
    fi
}

# Parse command-line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        -t|--type)
            NODE_TYPE="$2"
            shift 2
            ;;
        -i|--ip)
            NODE_IP="$2"
            shift 2
            ;;
        -f|--first-master)
            FIRST_RUN="true"
            shift
            ;;
        -m|--master-ip)
            MASTER_IP="$2"
            shift 2
            ;;
        -n|--hostname)
            CUSTOM_HOSTNAME="$2"
            shift 2
            ;;
        *)
            log "ERROR" "Unknown option: $1" >&2
            show_help
            ;;
    esac
done

# Validate required parameters
if [ -z "$NODE_TYPE" ]; then
    log "ERROR" "Node type (--type) is required. Use 'master' or 'worker'." >&2
    show_help
fi

if [[ "$NODE_TYPE" != "master" && "$NODE_TYPE" != "worker" ]]; then
    log "ERROR" "Node type must be 'master' or 'worker'" >&2
    show_help
fi

if [ -z "$NODE_IP" ]; then
    log "INFO" "No IP address provided. Attempting to auto-detect..."
    NODE_IP=$(detect_primary_ip)
    if [ -z "$NODE_IP" ]; then
        log "ERROR" "Failed to auto-detect IP address. Please specify with --ip option." >&2
        exit 1
    fi
    log "SUCCESS" "Auto-detected IP address: $NODE_IP"
fi

if ! [[ "$NODE_IP" =~ $IP_REGEX ]]; then
    log "ERROR" "Invalid format for Node IP address: $NODE_IP" >&2
    exit 1
fi

if [ "$NODE_TYPE" = "master" ] && [ "$FIRST_RUN" = "true" ] && [ -z "$MASTER_IP" ]; then
    MASTER_IP="$NODE_IP"
    log "INFO" "First master node detected. Setting MASTER_IP to $MASTER_IP"
elif [ "$FIRST_RUN" = "false" ] && [ -z "$MASTER_IP" ]; then
    log "ERROR" "Master IP (--master-ip) is required for worker nodes or additional master nodes" >&2
    show_help
fi

if [ -n "$MASTER_IP" ] && ! [[ "$MASTER_IP" =~ $IP_REGEX ]]; then
    log "ERROR" "Invalid format for Master IP address: $MASTER_IP" >&2
    exit 1
fi

# Set hostname if needed
if [ "$NODE_TYPE" = "master" ] && [ "$FIRST_RUN" = "true" ]; then
    if [ -n "$CUSTOM_HOSTNAME" ]; then
        CONTROL_PLANE_HOSTNAME="$CUSTOM_HOSTNAME"
    fi
    set_hostname_if_needed "$CONTROL_PLANE_HOSTNAME"
elif [ -n "$CUSTOM_HOSTNAME" ]; then
    set_hostname_if_needed "$CUSTOM_HOSTNAME"
fi

# Initialize summary file
echo "KUBERNETES $K8S_VERSION NODE SETUP SUMMARY" > "$SUMMARY_FILE"
echo "=======================================" >> "$SUMMARY_FILE"
echo "Date: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SUMMARY_FILE"
echo "Node Type: $NODE_TYPE" >> "$SUMMARY_FILE"
echo "Node IP: $NODE_IP" >> "$SUMMARY_FILE"
echo "Master IP (Control Plane Endpoint IP): $MASTER_IP" >> "$SUMMARY_FILE"
echo "Control Plane Hostname: $CONTROL_PLANE_HOSTNAME" >> "$SUMMARY_FILE"
echo "First Master Role: $FIRST_RUN" >> "$SUMMARY_FILE"
echo "Log File: $LOG_FILE" >> "$SUMMARY_FILE"
echo "---------------------------------------" >> "$SUMMARY_FILE"
echo "" >> "$SUMMARY_FILE"

# Step 1: Update package lists
log "INFO" "Checking package lists..."
apt_update_needed=$(find /var/lib/apt/lists -maxdepth 1 -mtime +1 2>/dev/null | wc -l) || apt_update_needed=1
if [ "$apt_update_needed" -gt 0 ]; then
    log "INFO" "Updating package lists..."
    if apt-get update; then
        log "SUCCESS" "Package lists updated successfully"
        add_to_summary "DONE" "Updated package lists"
    else
        log "ERROR" "Failed to update package lists"
        add_to_summary "FAILED" "Package list update"
        exit 1
    fi
else
    log "INFO" "Package lists are up to date (checked mtime +1 day)"
    add_to_summary "SKIPPED" "Package lists already up to date"
fi

# Step 2: Install required packages
log "INFO" "Checking required packages..."
required_packages="apt-transport-https ca-certificates curl software-properties-common gnupg"
missing_packages=""
for package in $required_packages; do
    if ! dpkg -l | grep -q "^ii\s\+$package\s"; then
        missing_packages="${missing_packages} $package"
    fi
done
if [ -n "$missing_packages" ]; then
    log "INFO" "Installing missing packages:${missing_packages}"
    if apt-get install -y $missing_packages; then
        log "SUCCESS" "Required packages installed successfully"
        add_to_summary "DONE" "Installed required packages:${missing_packages}"
    else
        log "ERROR" "Failed to install required packages"
        add_to_summary "FAILED" "Package installation"
        exit 1
    fi
else
    log "INFO" "All required packages are already installed"
    add_to_summary "SKIPPED" "All required packages already installed"
fi

# Step 3: Disable swap
log "INFO" "Checking swap status..."
swap_enabled=$(swapon --show 2>/dev/null | wc -l) || swap_enabled=0
fstab_has_swap=$(grep -v "^#" /etc/fstab 2>/dev/null | grep -c swap) || fstab_has_swap=0
if [ "$swap_enabled" -gt 0 ]; then
    log "INFO" "Disabling swap..."
    if swapoff -a; then
        log "SUCCESS" "Swap disabled successfully"
        add_to_summary "DONE" "Disabled swap"
    else
        log "ERROR" "Failed to disable swap"
        add_to_summary "FAILED" "Swap disabling"
        exit 1
    fi
else
    log "INFO" "Swap is already disabled"
    add_to_summary "SKIPPED" "Swap already disabled"
fi
if [ "$fstab_has_swap" -gt 0 ]; then
    log "INFO" "Commenting out swap in fstab..."
    if backup_file "/etc/fstab"; then
        if sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab; then
            log "SUCCESS" "Swap entries in fstab commented out"
            add_to_summary "DONE" "Commented out swap in fstab"
        else
            log "ERROR" "Failed to comment out swap in fstab"
            add_to_summary "FAILED" "Modifying fstab"
            exit 1
        fi
    fi
else
    log "INFO" "Swap already commented out in fstab"
    add_to_summary "SKIPPED" "Swap already commented out in fstab"
fi

# Step 4: Configure kernel modules
log "INFO" "Configuring kernel modules (overlay, br_netfilter)..."
modules_conf_file="/etc/modules-load.d/k8s.conf"
if [ ! -f "$modules_conf_file" ] || ! grep -q "^overlay$" "$modules_conf_file" || ! grep -q "^br_netfilter$" "$modules_conf_file"; then
    log "INFO" "Creating/updating kernel modules configuration file $modules_conf_file..."
    mkdir -p "$(dirname "$modules_conf_file")"
    if backup_file "$modules_conf_file"; then
        cat <<EOF > "$modules_conf_file"
overlay
br_netfilter
EOF
        log "SUCCESS" "Kernel modules configuration created/updated in $modules_conf_file"
        add_to_summary "DONE" "Configured kernel modules file"
    else
        log "ERROR" "Failed to configure kernel modules file"
        add_to_summary "FAILED" "Kernel modules configuration"
        exit 1
    fi
else
    log "INFO" "Kernel modules configuration already exists in $modules_conf_file"
    add_to_summary "SKIPPED" "Kernel modules configuration file already correct"
fi
log "INFO" "Loading kernel modules..."
if ! modprobe overlay; then
    log "WARNING" "Overlay module failed to load. Kubernetes may not function correctly."
    add_to_summary "WARNING" "Overlay module failed to load"
else
    log "SUCCESS" "Overlay module loaded successfully"
fi
if ! modprobe br_netfilter; then
    log "WARNING" "br_netfilter module failed to load. Kubernetes networking may fail."
    add_to_summary "WARNING" "br_netfilter module failed to load"
else
    log "SUCCESS" "br_netfilter module loaded successfully"
fi
add_to_summary "DONE" "Attempted to load kernel modules"

# Step 5: Set up sysctl parameters
log "INFO" "Configuring sysctl parameters for Kubernetes..."
sysctl_conf_file="/etc/sysctl.d/k8s.conf"
if [ ! -f "$sysctl_conf_file" ] ||
   ! grep -q "^net.bridge.bridge-nf-call-iptables\s*=\s*1$" "$sysctl_conf_file" ||
   ! grep -q "^net.bridge.bridge-nf-call-ip6tables\s*=\s*1$" "$sysctl_conf_file" ||
   ! grep -q "^net.ipv4.ip_forward\s*=\s*1$" "$sysctl_conf_file"; then
    log "INFO" "Creating/updating sysctl parameters file $sysctl_conf_file..."
    mkdir -p "$(dirname "$sysctl_conf_file")"
    if backup_file "$sysctl_conf_file"; then
        cat <<EOF > "$sysctl_conf_file"
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF
        log "SUCCESS" "Sysctl parameters configuration created/updated in $sysctl_conf_file"
        add_to_summary "DONE" "Configured sysctl parameters file"
    else
        log "ERROR" "Failed to configure sysctl parameters file"
        add_to_summary "FAILED" "Sysctl parameters configuration"
        exit 1
    fi
else
    log "INFO" "Sysctl parameters configuration already exists in $sysctl_conf_file"
    add_to_summary "SKIPPED" "Sysctl parameters file already correct"
fi
log "INFO" "Applying sysctl parameters..."
if ! sysctl --system; then
    log "WARNING" "Some sysctl parameters may have failed to apply, but continuing anyway"
else
    log "SUCCESS" "Sysctl parameters applied successfully"
fi
add_to_summary "DONE" "Attempted to apply sysctl parameters"

# Step 6: Install containerd
log "INFO" "Checking containerd installation..."
if ! command_exists containerd; then
    log "INFO" "Containerd not found. Installing containerd..."
    apt-get update
    if apt-get install -y containerd; then
        log "SUCCESS" "Containerd installed successfully"
        add_to_summary "DONE" "Installed containerd"
    else
        log "ERROR" "Failed to install containerd"
        add_to_summary "FAILED" "Containerd installation"
        exit 1
    fi
else
    log "INFO" "Containerd already installed"
    add_to_summary "SKIPPED" "Containerd already installed"
fi

# Step 7: Configure containerd
log "INFO" "Configuring containerd..."
containerd_conf_file="/etc/containerd/config.toml"
if [ ! -f "$containerd_conf_file" ] || ! grep -q 'SystemdCgroup = true' "$containerd_conf_file"; then
    log "INFO" "Creating/updating containerd configuration for SystemdCgroup..."
    mkdir -p "$(dirname "$containerd_conf_file")"
    if backup_file "$containerd_conf_file"; then
        if containerd config default > "$containerd_conf_file"; then
            if sed -i 's/SystemdCgroup = false/SystemdCgroup = true/g' "$containerd_conf_file"; then
                log "SUCCESS" "Containerd configuration updated to use SystemdCgroup"
                add_to_summary "DONE" "Configured containerd"
            else
                log "ERROR" "Failed to set SystemdCgroup=true in containerd config"
                add_to_summary "FAILED" "Configure containerd cgroup"
                exit 1
            fi
        else
            log "ERROR" "Failed to generate default containerd config"
            add_to_summary "FAILED" "Generate containerd config"
            exit 1
        fi
    else
        log "ERROR" "Failed to backup containerd config"
        add_to_summary "FAILED" "Backup containerd config"
        exit 1
    fi
else
    log "INFO" "Containerd configuration already set to use SystemdCgroup"
    add_to_summary "SKIPPED" "Containerd already configured correctly"
fi
if [ -f "$containerd_conf_file" ] && grep -q 'SystemdCgroup = true' "$containerd_conf_file"; then
    log "INFO" "Restarting containerd service after configuration update..."
    if systemctl restart containerd; then
        log "SUCCESS" "Containerd service restarted"
        add_to_summary "DONE" "Restarted containerd service"
    else
        log "ERROR" "Failed to restart containerd service"
        add_to_summary "FAILED" "Containerd service restart"
        exit 1
    fi
fi
if ! service_enabled containerd; then
    log "INFO" "Enabling containerd service..."
    if systemctl enable containerd; then
        log "SUCCESS" "Containerd service enabled"
        add_to_summary "DONE" "Enabled containerd service"
    else
        log "ERROR" "Failed to enable containerd service"
        add_to_summary "FAILED" "Enabling containerd service"
        exit 1
    fi
else
    log "INFO" "Containerd service already enabled"
    add_to_summary "SKIPPED" "Containerd service already enabled"
fi

# Step 8: Add Kubernetes repository
log "INFO" "Configuring Kubernetes repository..."
k8s_repo_keyring="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
k8s_repo_list="/etc/apt/sources.list.d/kubernetes.list"
if [ ! -f "$k8s_repo_keyring" ] || [ ! -f "$k8s_repo_list" ] || ! grep -q "pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb" "$k8s_repo_list"; then
    log "INFO" "Adding Kubernetes repository for v${K8S_VERSION}..."
    mkdir -p "$(dirname "$k8s_repo_keyring")"
    if curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -o "$k8s_repo_keyring"; then
        echo "deb [signed-by=$k8s_repo_keyring] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > "$k8s_repo_list"
        log "SUCCESS" "Kubernetes repository added"
        add_to_summary "DONE" "Added Kubernetes repository"
    else
        log "ERROR" "Failed to add Kubernetes repository"
        add_to_summary "FAILED" "Adding Kubernetes repository"
        exit 1
    fi
else
    log "INFO" "Kubernetes repository for v${K8S_VERSION} already configured"
    add_to_summary "SKIPPED" "Kubernetes repository already configured"
fi

# Step 9: Install Kubernetes components
log "INFO" "Checking Kubernetes components installation..."
k8s_components="kubelet kubeadm kubectl"
missing_components=""
for component in $k8s_components; do
    if ! command_exists "$component"; then
        missing_components="${missing_components} $component"
    fi
done
if [ -n "$missing_components" ]; then
    log "INFO" "Installing Kubernetes components:${missing_components}"
    apt-get update
    if apt-get install -y $missing_components; then
        log "SUCCESS" "Kubernetes components installed successfully"
        add_to_summary "DONE" "Installed Kubernetes components"
    else
        log "ERROR" "Failed to install Kubernetes components"
        add_to_summary "FAILED" "Kubernetes components installation"
        exit 1
    fi
else
    log "INFO" "All Kubernetes components already installed"
    add_to_summary "SKIPPED" "Kubernetes components already installed"
fi

# Step 10: Hold Kubernetes component versions
log "INFO" "Setting hold on Kubernetes component versions..."
if apt-mark hold kubelet kubeadm kubectl; then
    log "SUCCESS" "Kubernetes component versions held successfully"
    add_to_summary "DONE" "Set hold on Kubernetes components"
else
    log "WARNING" "Failed to hold Kubernetes component versions, but continuing"
    add_to_summary "WARNING" "Failed to set hold on Kubernetes components"
fi

# Step 11: Configure hosts file
log "INFO" "Configuring hosts file for control plane endpoint: ${CONTROL_PLANE_HOSTNAME} -> ${MASTER_IP}..."
if ! grep -q "^${MASTER_IP}\s\+${CONTROL_PLANE_HOSTNAME}\s*$" /etc/hosts; then
    if grep -q "\s${CONTROL_PLANE_HOSTNAME}\s*$" /etc/hosts; then
        log "INFO" "Updating hosts entry for ${CONTROL_PLANE_HOSTNAME} to IP ${MASTER_IP}..."
        if backup_file "/etc/hosts"; then
            sed -i "s/.*\\s${CONTROL_PLANE_HOSTNAME}\\s*$/${MASTER_IP}\\t${CONTROL_PLANE_HOSTNAME}/g" /etc/hosts
            log "SUCCESS" "Updated hosts entry for ${CONTROL_PLANE_HOSTNAME} to ${MASTER_IP}"
            add_to_summary "DONE" "Updated hosts entry for ${CONTROL_PLANE_HOSTNAME}"
        else
            log "ERROR" "Failed to backup /etc/hosts"
            add_to_summary "FAILED" "Backup /etc/hosts"
            exit 1
        fi
    else
        log "INFO" "Adding hosts entry for ${CONTROL_PLANE_HOSTNAME} (${MASTER_IP})..."
        if backup_file "/etc/hosts"; then
            echo "${MASTER_IP}	${CONTROL_PLANE_HOSTNAME}" >> /etc/hosts
            log "SUCCESS" "Added hosts entry ${MASTER_IP} ${CONTROL_PLANE_HOSTNAME} to /etc/hosts"
            add_to_summary "DONE" "Added hosts entry for ${CONTROL_PLANE_HOSTNAME}"
        else
            log "ERROR" "Failed to backup /etc/hosts"
            add_to_summary "FAILED" "Backup /etc/hosts"
            exit 1
        fi
    fi
else
    log "INFO" "Hosts file already contains correct entry for ${CONTROL_PLANE_HOSTNAME} (${MASTER_IP})"
    add_to_summary "SKIPPED" "Hosts entry for ${CONTROL_PLANE_HOSTNAME} already exists"
fi
log "WARNING" "Please ensure other necessary hostnames are resolvable via DNS or manually configured in /etc/hosts."
add_to_summary "INFO" "Verify other necessary host entries"

# Step 12: Configure firewall
log "INFO" "Checking firewall status..."
if command_exists ufw && ufw status | grep -q "Status: active"; then
    log "INFO" "UFW firewall is active. Configuring rules for Kubernetes..."
    if [ "$NODE_TYPE" = "master" ]; then
        ports=("6443/tcp" "2379:2380/tcp" "10250/tcp" "10259/tcp" "10257/tcp" "30000:32767/tcp")
    else
        ports=("10250/tcp" "30000:32767/tcp")
    fi
    for port in "${ports[@]}"; do
        if ! ufw status | grep -q "ALLOW\s\+${port}"; then
            log "INFO" "Adding firewall rule for $port (UFW)"
            if ufw allow "$port"; then
                log "SUCCESS" "Added firewall rule for $port (UFW)"
                add_to_summary "DONE" "Added UFW rule for $port"
            else
                log "WARNING" "Failed to add UFW rule for $port"
                add_to_summary "WARNING" "Failed to add UFW rule for $port"
            fi
        else
            log "INFO" "Firewall rule for $port already exists (UFW)"
            add_to_summary "SKIPPED" "UFW rule for $port already exists"
        fi
    done
elif command_exists firewalld && systemctl is-active --quiet firewalld; then
    log "WARNING" "Firewalld is active. This script does not automatically configure firewalld. Please configure manually."
    add_to_summary "WARNING" "Firewalld active - requires manual configuration"
else
    log "INFO" "No active UFW or firewalld detected. Skipping firewall configuration."
    add_to_summary "SKIPPED" "No active firewall detected"
fi

# Step 13: Set up first master node
if [ "$NODE_TYPE" = "master" ] && [ "$FIRST_RUN" = "true" ]; then
    log "INFO" "Setting up first master node with kubeadm init..."
    if [ -f "/etc/kubernetes/admin.conf" ]; then
        log "INFO" "Kubernetes cluster appears to be already initialized on this node."
        add_to_summary "SKIPPED" "Kubernetes cluster already initialized"
    else
        log "INFO" "Running kubeadm init..."
        cat <<EOF > /root/kubeadm-config.yaml
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}.0
controlPlaneEndpoint: "${CONTROL_PLANE_HOSTNAME}:6443"
networking:
  podSubnet: "10.244.0.0/16"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
        if kubeadm init --config=/root/kubeadm-config.yaml --upload-certs > /root/kubeadm-init.log 2>&1; then
            log "SUCCESS" "Kubernetes cluster initialized successfully."
            add_to_summary "DONE" "Initialized Kubernetes control plane"
            control_plane_join_cmd=$(grep -A 2 -- "control-plane" /root/kubeadm-init.log | grep "kubeadm join")
            certificate_key=$(grep "certificate-key" /root/kubeadm-init.log | awk '{print $NF}')
            worker_join_cmd=$(grep "kubeadm join" /root/kubeadm-init.log | grep -v -- "--control-plane")
            echo "Control Plane Join Command: $control_plane_join_cmd --certificate-key $certificate_key" > /root/k8s_join_commands.txt
            echo "Worker Join Command: $worker_join_cmd" >> /root/k8s_join_commands.txt
            log "SUCCESS" "Join commands saved to /root/k8s_join_commands.txt"
            add_to_summary "INFO" "Join commands saved to /root/k8s_join_commands.txt"
            mkdir -p /root/.kube
            cp /etc/kubernetes/admin.conf /root/.kube/config
            chown $(id -u):$(id -g) /root/.kube/config
            log "SUCCESS" "kubectl configured for root user"
            add_to_summary "DONE" "Configured kubectl for root user"

            # Install and verify Calico CNI plugin
            log "INFO" "Installing Calico CNI plugin..."
            # Wait for API server to be ready
            retries=30
            until kubectl get nodes >/dev/null 2>&1 || [ $retries -eq 0 ]; do
                log "INFO" "Waiting for Kubernetes API server to be ready... ($retries retries left)"
                sleep 10
                retries=$((retries - 1))
            done
            if [ $retries -eq 0 ]; then
                log "ERROR" "Kubernetes API server not ready after waiting. Cannot install Calico."
                add_to_summary "FAILED" "Kubernetes API server readiness check"
                exit 1
            fi

            # Check if Calico is already installed
            if kubectl get pods -n kube-system | grep -q "calico"; then
                log "INFO" "Calico CNI plugin appears to be already installed."
                add_to_summary "SKIPPED" "Calico CNI plugin already installed"
            else
                # Attempt to install Calico with retries
                max_attempts=3
                attempt=1
                while [ $attempt -le $max_attempts ]; do
                    log "INFO" "Attempting to install Calico CNI plugin (Attempt $attempt/$max_attempts)..."
                    if kubectl apply -f https://docs.projectcalico.org/manifests/calico.yaml; then
                        log "SUCCESS" "Calico CNI plugin applied successfully"
                        break
                    else
                        log "WARNING" "Failed to apply Calico CNI plugin on attempt $attempt"
                        sleep 5
                    fi
                    attempt=$((attempt + 1))
                done

                if [ $attempt -gt $max_attempts ]; then
                    log "ERROR" "Failed to install Calico CNI plugin after $max_attempts attempts."
                    add_to_summary "FAILED" "Calico CNI plugin installation"
                    exit 1
                else
                    add_to_summary "DONE" "Installed Calico CNI plugin"
                fi
            fi

            # Verify Calico pods are running
            log "INFO" "Verifying Calico CNI plugin installation..."
            retries=30 # Wait up to 2 minutes (12 * 10 seconds)
            until kubectl get pods -n kube-system | grep calico | grep -q Running || [ $retries -eq 0 ]; do
                log "INFO" "Waiting for Calico pods to be in Running state... ($retries retries left)"
                sleep 10
                retries=$((retries - 1))
            done
            if [ $retries -eq 0 ]; then
                log "ERROR" "Calico pods are not running after waiting. Cluster networking may not function."
                add_to_summary "FAILED" "Calico CNI plugin verification"
                exit 1
            else
                log "SUCCESS" "Calico CNI plugin verified running successfully"
                add_to_summary "DONE" "Verified Calico CNI plugin running"
            fi
        else
            log "ERROR" "Failed to initialize Kubernetes cluster. Check /root/kubeadm-init.log"
            add_to_summary "FAILED" "Kubernetes cluster initialization"
            exit 1
        fi
    fi
    if [ -n "$SUDO_USER" ] && [ "$SUDO_USER" != "root" ]; then
        KUBE_USER_HOME=$(eval echo "~$SUDO_USER")
        log "INFO" "Setting up kubectl for user $SUDO_USER..."
        mkdir -p "$KUBE_USER_HOME/.kube"
        cp /etc/kubernetes/admin.conf "$KUBE_USER_HOME/.kube/config"
        chown -R "$SUDO_USER:$(id -gn $SUDO_USER)" "$KUBE_USER_HOME/.kube"
        log "SUCCESS" "kubectl configured for user $SUDO_USER"
        add_to_summary "DONE" "Configured kubectl for $SUDO_USER"
    else
        NON_ROOT_USER=$(find_non_root_user)
        if [ -n "$NON_ROOT_USER" ]; then
            USER_HOME=$(eval echo "~$NON_ROOT_USER")
            log "INFO" "Setting up kubectl for user $NON_ROOT_USER..."
            mkdir -p "$USER_HOME/.kube"
            cp /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
            chown -R "$NON_ROOT_USER:$(id -gn $NON_ROOT_USER)" "$USER_HOME/.kube"
            log "SUCCESS" "kubectl configured for user $NON_ROOT_USER"
            add_to_summary "DONE" "Configured kubectl for $NON_ROOT_USER"
        fi
    fi
fi

# Step 14: Verify kubelet service
log "INFO" "Checking kubelet service status..."
if ! service_running kubelet; then
    log "INFO" "Kubelet service is not running. Attempting to start..."
    if systemctl start kubelet; then
        log "SUCCESS" "kubelet service started"
        add_to_summary "DONE" "Started kubelet service"
    else
        log "WARNING" "Failed to start kubelet service. This may be normal before joining the cluster."
        add_to_summary "INFO" "kubelet service not running (normal before cluster join)"
    fi
else
    log "INFO" "Kubelet service already running"
    add_to_summary "SKIPPED" "kubelet service already running"
fi
if ! service_enabled kubelet; then
    log "INFO" "Enabling kubelet service..."
    if systemctl enable kubelet; then
        log "SUCCESS" "kubelet service enabled"
        add_to_summary "DONE" "Enabled kubelet service"
    else
        log "ERROR" "Failed to enable kubelet service"
        add_to_summary "FAILED" "Enabling kubelet service"
        exit 1
    fi
else
    log "INFO" "Kubelet service already enabled"
    add_to_summary "SKIPPED" "kubelet service already enabled"
fi

# Step 15: Generate summary report
log "INFO" "Generating setup summary..."
echo "" >> "$SUMMARY_FILE"
echo "===============================================" >> "$SUMMARY_FILE"
echo "SETUP COMPLETED: $(date '+%Y-%m-%d %H:%M:%S')" >> "$SUMMARY_FILE"
echo "===============================================" >> "$SUMMARY_FILE"

echo ""
echo "==============================================="
echo -e "${GREEN}KUBERNETES NODE PREPARATION COMPLETE${NC}"
echo "==============================================="
echo ""
echo "Summary of actions taken:"
cat "$SUMMARY_FILE"
echo ""

if [ "$NODE_TYPE" = "master" ] && [ "$FIRST_RUN" = "true" ]; then
    echo -e "${YELLOW}NEXT STEPS:${NC}"
    if [ -f "/root/k8s_join_commands.txt" ]; then
        echo "1. Review join commands in /root/k8s_join_commands.txt"
        echo "2. Run the appropriate join command on other master and worker nodes."
    else
        echo "1. kubeadm init may have failed. Check logs: $LOG_FILE"
        echo "2. If successful, manually generate join commands:"
        echo "   For control plane: sudo kubeadm token create --print-join-command"
        echo "                      sudo kubeadm init phase upload-certs --upload-certs"
        echo "   For workers:       sudo kubeadm token create --print-join-command"
    fi
    echo "3. Verify your cluster status: kubectl get nodes"
    echo ""
elif [ "$NODE_TYPE" = "master" ] && [ "$FIRST_RUN" != "true" ]; then
    echo -e "${YELLOW}NEXT STEPS (Additional Master Node):${NC}"
    echo "1. On the ${CONTROL_PLANE_HOSTNAME} node (${MASTER_IP}), generate a control plane join command:"
    echo "   sudo kubeadm token create --print-join-command"
    echo "   sudo kubeadm init phase upload-certs --upload-certs # Get the certificate key"
    echo "2. On *this* node (${NODE_IP}), run the generated command with --control-plane and --certificate-key."
    echo "3. Verify node status on ${CONTROL_PLANE_HOSTNAME}: kubectl get nodes"
    echo ""
elif [ "$NODE_TYPE" = "worker" ]; then
    echo -e "${YELLOW}NEXT STEPS (Worker Node):${NC}"
    echo "1. On the ${CONTROL_PLANE_HOSTNAME} node (${MASTER_IP}), generate a worker join command:"
    echo "   sudo kubeadm token create --print-join-command"
    echo "2. On *this* node (${NODE_IP}), run the generated command."
    echo "3. Verify node status on ${CONTROL_PLANE_HOSTNAME}: kubectl get nodes"
    echo ""
fi

echo -e "${BLUE}Detailed logs are available in: $LOG_FILE${NC}"
echo -e "${BLUE}Node preparation complete!${NC}"
echo ""

cp "$SUMMARY_FILE" /root/k8s_setup_summary_latest.txt
log "INFO" "Summary saved to /root/k8s_setup_summary_latest.txt"

exit 0
