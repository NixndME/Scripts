#!/bin/bash

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# Clear the screen
clear

# Function to display server information
display_server_info() {
    echo -e "${YELLOW}Server Information:${NC}"
    echo -e "Hostname: $(hostname)"
    echo -e "OS: $(lsb_release -ds)"
    echo -e "Kernel: $(uname -r)"
    echo -e "CPU: $(lscpu | grep 'Model name' | cut -f 2 -d ":" | awk '{$1=$1}1')"
    echo -e "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    echo -e "Disk: $(df -h --output=size / | sed '1d;s/[^0-9]//g')GB\n"
}

# Function to check if KVM is supported
check_kvm() {
    if grep -E 'svm|vmx' /proc/cpuinfo > /dev/null 2>&1; then
        echo -e "${GREEN}✔ KVM is supported on this system.${NC}"
        return 0
    else
        echo -e "${RED}✘ KVM is not supported on this system.${NC}"
        return 1
    fi
}

# Function to check if IP is static
check_static_ip() {
    if grep -q "addresses:" /etc/netplan/*.yaml 2>/dev/null; then
        echo -e "${GREEN}✔ IP is set to static (Netplan configuration detected).${NC}"
        return 0
    elif grep -q "static" /etc/network/interfaces 2>/dev/null; then
        echo -e "${GREEN}✔ IP is set to static (legacy networking configuration detected).${NC}"
        return 0
    else
        echo -e "${RED}✘ IP is not set to static.${NC}"
        return 1
    fi
}

# Function to check proxy settings
check_proxy() {
    proxy_set=false
    no_proxy_correct=false
    
    # Check if proxy is set
    if env | grep -Eiq '(http_proxy|https_proxy|ftp_proxy)'; then
        proxy_set=true
    fi
    
    # Check proxy settings in various files
    if grep -q 'Acquire::(http|https)::proxy' /etc/apt/apt.conf 2>/dev/null || \
       grep -q 'export.*_proxy=' /etc/profile 2>/dev/null || \
       grep -q 'Acquire::(http|https)::Proxy' /etc/apt/apt.conf.d/99no-proxy 2>/dev/null; then
        proxy_set=true
    fi
    
    # If proxy is set, check for correct no_proxy settings
    if $proxy_set; then
        if grep -q 'export no_proxy=.*localhost.*,127\.0\.0\.1' /etc/profile 2>/dev/null || \
           grep -qE 'Acquire::(http|https)::Proxy.*("127\.0\.0\.1"|"localhost").*"DIRECT"' /etc/apt/apt.conf.d/99no-proxy 2>/dev/null; then
            no_proxy_correct=true
        fi
    fi
    
    # Check internet connectivity
    if ping -c 1 8.8.8.8 &> /dev/null; then
        internet_access=true
    else
        internet_access=false
    fi
    
    # Evaluate scenarios
    if ! $proxy_set && $internet_access; then
        echo -e "${GREEN}✔ No proxy set and internet is accessible. Suitable for MVM installation.${NC}"
        return 0
    elif ! $proxy_set && ! $internet_access; then
        echo -e "${RED}✘ No proxy set but internet is not accessible. MVM installation may face issues.${NC}"
        return 1
    elif $proxy_set && $no_proxy_correct; then
        echo -e "${GREEN}✔ Proxy is set with correct no_proxy settings for localhost/127.0.0.1. Suitable for MVM installation.${NC}"
        return 0
    elif $proxy_set && ! $no_proxy_correct; then
        echo -e "${RED}✘ Proxy is set but no_proxy settings for localhost/127.0.0.1 are missing or incorrect.${NC}"
        echo -e "${YELLOW}   Tip: Add 'localhost,127.0.0.1' to no_proxy in /etc/profile or /etc/apt/apt.conf.d/99no-proxy${NC}"
        return 1
    fi
}

# Function to check disk size
check_disk_size() {
    disk_size=$(df -BG / | awk 'NR==2 {print $2}' | sed 's/G//')
    if [ "$disk_size" -gt 48 ]; then
        echo -e "${GREEN}✔ Disk size is more than 50GB: ${disk_size}GB${NC}"
        return 0
    else
        echo -e "${RED}✘ Disk size is less than or equal to 50GB: ${disk_size}GB${NC}"
        return 1
    fi
}

# Function to check Morpheus connectivity
check_morpheus_connectivity() {
    local morpheus_hostname=$1
    local morpheus_ip=$2

    echo -e "\n${YELLOW}Checking Morpheus connectivity...${NC}"

    # Try connecting using hostname
    if curl -s "https://${morpheus_hostname}/ping" -k | grep -q "MORPHEUS PING"; then
        echo -e "${GREEN}✔ Successfully connected to Morpheus using hostname: ${morpheus_hostname}${NC}"
        return 0
    # Try connecting using IP address
    elif curl -s "https://${morpheus_ip}/ping" -k | grep -q "MORPHEUS PING"; then
        echo -e "${GREEN}✔ Successfully connected to Morpheus using IP: ${morpheus_ip}${NC}"
        return 0
    else
        echo -e "${RED}✘ Failed to connect to Morpheus using both hostname and IP${NC}"
        return 1
    fi
}

# Function to check if Morpheus details are in /etc/hosts
check_etc_hosts() {
    local morpheus_hostname=$1
    local morpheus_ip=$2

    echo -e "\n${YELLOW}Checking if Morpheus details are in /etc/hosts...${NC}"

    if grep -q "${morpheus_ip}\s*${morpheus_hostname}" /etc/hosts; then
        echo -e "${GREEN}✔ Morpheus details found in /etc/hosts${NC}"
        return 0
    else
        echo -e "${RED}✘ Morpheus details not found in /etc/hosts${NC}"
        echo -e "${YELLOW}   Tip: Add '${morpheus_ip} ${morpheus_hostname}' to /etc/hosts${NC}"
        return 1
    fi
}

# Initialize variables to store check results
kvm_check=""
static_ip_check=""
proxy_check=""
disk_size_check=""
morpheus_connectivity_check=""
etc_hosts_check=""

# Function to set check results
set_result() {
    case "$1" in
        "KVM Support") kvm_check=$2 ;;
        "Static IP") static_ip_check=$2 ;;
        "Proxy Settings") proxy_check=$2 ;;
        "Disk Size") disk_size_check=$2 ;;
        "Morpheus Connectivity") morpheus_connectivity_check=$2 ;;
        "Morpheus in /etc/hosts") etc_hosts_check=$2 ;;
    esac
}

# Main script execution
echo -e "${YELLOW}Running system checks for MVM Readiness on Ubuntu 22.04...${NC}\n"

display_server_info

# Get Morpheus details
read -p "Enter Morpheus Hostname: " morpheus_hostname
read -p "Enter Morpheus IP address: " morpheus_ip

# Perform checks
check_kvm
set_result "KVM Support" $?

check_static_ip
set_result "Static IP" $?

check_proxy
set_result "Proxy Settings" $?

check_disk_size
set_result "Disk Size" $?

check_morpheus_connectivity "$morpheus_hostname" "$morpheus_ip"
set_result "Morpheus Connectivity" $?

check_etc_hosts "$morpheus_hostname" "$morpheus_ip"
set_result "Morpheus in /etc/hosts" $?

echo -e "\n${YELLOW}Summary:${NC}"

# Display summary and check for failures
failed=false
for check in "KVM Support" "Static IP" "Proxy Settings" "Disk Size" "Morpheus Connectivity" "Morpheus in /etc/hosts"; do
    case "$check" in
        "KVM Support") result=$kvm_check ;;
        "Static IP") result=$static_ip_check ;;
        "Proxy Settings") result=$proxy_check ;;
        "Disk Size") result=$disk_size_check ;;
        "Morpheus Connectivity") result=$morpheus_connectivity_check ;;
        "Morpheus in /etc/hosts") result=$etc_hosts_check ;;
    esac

    if [ "$result" = "0" ]; then
        echo -e "${GREEN}✔ $check check passed.${NC}"
    else
        echo -e "${RED}✘ $check check failed.${NC}"
        failed=true
    fi
done

echo

if $failed; then
    echo -e "${RED}Some checks failed. Please fix the issues mentioned above to make this server MVM ready.${NC}"
else
    echo -e "${GREEN}┌────────────────────────────────────────────┐"
    echo -e "│                                            │"
    echo -e "│   All checks passed successfully!          │"
    echo -e "│   This server is supported for MVM node.   │"
    echo -e "│                                            │"
    echo -e "└────────────────────────────────────────────┘${NC}"
fi
