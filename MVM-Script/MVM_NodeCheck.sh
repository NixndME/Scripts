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

    # Check no_proxy in /etc/profile
    if grep -q 'export no_proxy=.*localhost.*,127\.0\.0\.1' /etc/profile 2>/dev/null; then
        no_proxy_correct=true
    fi

    # Check Acquire::http::Proxy and Acquire::https::Proxy in /etc/apt/apt.conf.d/99no-proxy
    if grep -qE 'Acquire::(http|https)::Proxy.*("127\.0\.0\.1"|"localhost").*"DIRECT"' /etc/apt/apt.conf.d/99no-proxy 2>/dev/null; then
        no_proxy_correct=true
    fi

    # Check proxy settings in /etc/apt/apt.conf
    if grep -q 'Acquire::(http|https)::proxy' /etc/apt/apt.conf 2>/dev/null; then
        proxy_set=true
    fi

    if $proxy_set; then
        if $no_proxy_correct; then
            echo -e "${GREEN}✔ Proxy is set, and localhost/127.0.0.1 is correctly configured in no_proxy.${NC}"
            return 0
        else
            echo -e "${RED}✘ Proxy is set, but localhost/127.0.0.1 might not be correctly configured in no_proxy.${NC}"
            echo -e "${YELLOW}   Tip: Check /etc/profile and /etc/apt/apt.conf.d/99no-proxy for correct no_proxy settings.${NC}"
            return 1
        fi
    else
        echo -e "${GREEN}✔ No proxy is set.${NC}"
        return 0
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

# Initialize variables to store check results
kvm_check=""
static_ip_check=""
proxy_check=""
disk_size_check=""

# Function to set check results
set_result() {
    case "$1" in
        "KVM Support") kvm_check=$2 ;;
        "Static IP") static_ip_check=$2 ;;
        "Proxy Settings") proxy_check=$2 ;;
        "Disk Size") disk_size_check=$2 ;;
    esac
}

# Main script execution
echo -e "${YELLOW}Running system checks for MVM Readiness on Ubuntu 22.04...${NC}\n"

display_server_info

# Perform checks
check_kvm
set_result "KVM Support" $?

check_static_ip
set_result "Static IP" $?

check_proxy
set_result "Proxy Settings" $?

check_disk_size
set_result "Disk Size" $?

echo -e "\n${YELLOW}Summary:${NC}"

# Display summary and check for failures
failed=false
for check in "KVM Support" "Static IP" "Proxy Settings" "Disk Size"; do
    case "$check" in
        "KVM Support") result=$kvm_check ;;
        "Static IP") result=$static_ip_check ;;
        "Proxy Settings") result=$proxy_check ;;
        "Disk Size") result=$disk_size_check ;;
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
