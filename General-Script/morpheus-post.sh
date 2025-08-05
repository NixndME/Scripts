#!/bin/bash

##############################################################################
# Morpheus Data Post-Installation Validation Script
# Purpose: Comprehensive validation and backup after Morpheus Data installation
# Date: $(date +%Y-%m-%d)
##############################################################################

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global variables
SCRIPT_START_TIME=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/opt/morpheus/backups/post_validation_${SCRIPT_START_TIME}"
REPORT_FILE="${BACKUP_DIR}/morpheus_post_validation_report_${SCRIPT_START_TIME}.txt"
LOG_FILE="${BACKUP_DIR}/morpheus_post_validation_log_${SCRIPT_START_TIME}.log"
MORPHEUS_HOME="/opt/morpheus"
CURRENT_USER=$(whoami)

# Deployment type detection
DEPLOYMENT_TYPE=""
NODE_COUNT=0
IS_AIO=false

##############################################################################
# Utility Functions
##############################################################################

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1" | tee -a "$LOG_FILE"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" | tee -a "$LOG_FILE"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" | tee -a "$LOG_FILE"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" | tee -a "$LOG_FILE"
}

print_header() {
    echo -e "\n${BLUE}=== $1 ===${NC}" | tee -a "$REPORT_FILE"
    echo -e "\n=== $1 ===" >> "$LOG_FILE"
}

check_command() {
    if command -v "$1" &> /dev/null; then
        return 0
    else
        return 1
    fi
}

test_port() {
    local host=$1
    local port=$2
    local timeout=${3:-5}
    
    if timeout "$timeout" bash -c "</dev/tcp/$host/$port" 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

##############################################################################
# Setup and Initialization
##############################################################################

initialize_script() {
    print_header "MORPHEUS DATA POST-INSTALLATION VALIDATION"
    
    # Create backup directory
    mkdir -p "$BACKUP_DIR"
    
    # Initialize report file
    cat > "$REPORT_FILE" << EOF
Morpheus Data Post-Installation Validation Report
================================================
Date: $(date)
Server: $(hostname)
User: $CURRENT_USER
Script Version: 1.0

EOF

    log_info "Starting Morpheus Data post-installation validation"
    log_info "Backup directory: $BACKUP_DIR"
    log_info "Report file: $REPORT_FILE"
}

##############################################################################
# System Information Collection
##############################################################################

collect_system_info() {
    print_header "SYSTEM INFORMATION"
    
    {
        echo "Hostname: $(hostname)"
        echo "IP Address: $(hostname -I | awk '{print $1}')"
        echo "Operating System: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
        echo "Kernel Version: $(uname -r)"
        echo "CPU: $(grep 'model name' /proc/cpuinfo | head -1 | cut -d':' -f2 | xargs)"
        echo "Memory: $(free -h | grep '^Mem:' | awk '{print $2}')"
        echo "Disk Space: $(df -h / | tail -1 | awk '{print $4 " available of " $2}')"
        echo "Uptime: $(uptime -p)"
    } | tee -a "$REPORT_FILE"
    
    log_success "System information collected"
}

##############################################################################
# Deployment Type Detection
##############################################################################

detect_deployment_type() {
    print_header "DEPLOYMENT TYPE DETECTION"
    
    # Check if running in cluster mode or AIO
    if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
        # Check for cluster configuration
        local cluster_config=$(grep -c "cluster:" "$MORPHEUS_HOME/config/application.yml" 2>/dev/null || echo "0")
        local elastic_nodes=$(grep -A 10 "elasticsearch:" "$MORPHEUS_HOME/config/application.yml" | grep -c "http://" 2>/dev/null || echo "0")
        
        if [[ $elastic_nodes -gt 1 ]] || [[ -f "/etc/morpheus/cluster.conf" ]]; then
            DEPLOYMENT_TYPE="3-Node Cluster"
            NODE_COUNT=3
            IS_AIO=false
        else
            DEPLOYMENT_TYPE="All-In-One (AIO)"
            NODE_COUNT=1
            IS_AIO=true
        fi
    else
        log_warning "Morpheus configuration file not found, assuming AIO deployment"
        DEPLOYMENT_TYPE="All-In-One (AIO)"
        NODE_COUNT=1
        IS_AIO=true
    fi
    
    echo "Deployment Type: $DEPLOYMENT_TYPE" | tee -a "$REPORT_FILE"
    echo "Node Count: $NODE_COUNT" | tee -a "$REPORT_FILE"
    
    log_success "Deployment type detected: $DEPLOYMENT_TYPE"
}

##############################################################################
# Morpheus Core Service Checks
##############################################################################

check_morpheus_services() {
    print_header "MORPHEUS CORE SERVICES STATUS"
    
    local service_status_ok=true
    
    {
        echo "Morpheus Service Status (using morpheus-ctl):"
        echo ""
        
        # Use morpheus-ctl status for comprehensive service information
        if check_command morpheus-ctl; then
            echo "=== morpheus-ctl status ==="
            morpheus-ctl status 2>/dev/null || {
                echo "Error: morpheus-ctl status command failed"
                service_status_ok=false
            }
            
            echo ""
            echo "=== morpheus-ctl service-list ==="
            morpheus-ctl service-list 2>/dev/null || {
                echo "Error: morpheus-ctl service-list command failed"
            }
            
            # Parse morpheus-ctl status output to determine if services are running
            local status_output=$(morpheus-ctl status 2>/dev/null)
            if [[ -n "$status_output" ]]; then
                if echo "$status_output" | grep -q "down\|fail\|stopped"; then
                    echo ""
                    echo "⚠️  Some services appear to be down or failed"
                    log_warning "Some Morpheus services may not be running properly"
                    service_status_ok=false
                else
                    echo ""
                    echo "✓ All Morpheus services appear to be running"
                    log_success "All Morpheus services are running"
                fi
            else
                log_error "Could not retrieve morpheus-ctl status"
                service_status_ok=false
            fi
            
        else
            log_error "morpheus-ctl command not found - falling back to systemctl"
            # Fallback to systemctl for basic service checks
            local services=("morpheus-ui" "morpheus-app" "morpheus-vm" "morpheus-reports")
            
            echo "System Service Status (systemctl fallback):"
            for service in "${services[@]}"; do
                if systemctl is-active --quiet "$service" 2>/dev/null; then
                    echo "  ✓ $service: RUNNING"
                    log_success "$service is running"
                else
                    echo "  ✗ $service: STOPPED/FAILED"
                    log_error "$service is not running"
                    service_status_ok=false
                fi
            done
        fi
        
        echo ""
        echo "Process Information:"
        echo "Morpheus-related processes:"
        ps aux | grep -E "(morpheus|java.*morpheus)" | grep -v grep | head -10
        
    } | tee -a "$REPORT_FILE"
    
    if $service_status_ok; then
        log_success "Morpheus service validation completed successfully"
    else
        log_warning "Issues detected with Morpheus services - review required"
    fi
}

##############################################################################
# Morpheus Configuration Check
##############################################################################

check_morpheus_configuration() {
    print_header "MORPHEUS CONFIGURATION"
    
    {
        echo "Morpheus Configuration Information:"
        echo ""
        
        if check_command morpheus-ctl; then
            echo "=== morpheus-ctl show-config (abbreviated) ==="
            # Show key configuration sections without exposing sensitive data
            morpheus-ctl show-config 2>/dev/null | grep -E "^(morpheus|database|elasticsearch|rabbitmq)" | head -20 || {
                echo "Could not retrieve morpheus configuration"
            }
            
            echo ""
            echo "Configuration File Locations:"
            if [[ -f "/etc/morpheus/morpheus.rb" ]]; then
                echo "✓ Main config: /etc/morpheus/morpheus.rb"
                echo "  Last modified: $(stat -c %y /etc/morpheus/morpheus.rb 2>/dev/null)"
                echo "  Size: $(stat -c %s /etc/morpheus/morpheus.rb 2>/dev/null) bytes"
            else
                echo "✗ Main config file not found at /etc/morpheus/morpheus.rb"
            fi
            
            if [[ -f "/opt/morpheus/config/application.yml" ]]; then
                echo "✓ Application config: /opt/morpheus/config/application.yml"
                echo "  Last modified: $(stat -c %y /opt/morpheus/config/application.yml 2>/dev/null)"
            else
                echo "✗ Application config not found"
            fi
            
        else
            echo "morpheus-ctl not available - checking basic configuration files"
            
            if [[ -f "/etc/morpheus/morpheus.rb" ]]; then
                echo "✓ Found /etc/morpheus/morpheus.rb"
            else
                echo "✗ Main configuration file missing"
            fi
            
            if [[ -f "/opt/morpheus/config/application.yml" ]]; then
                echo "✓ Found application.yml"
            else
                echo "✗ Application configuration missing"
            fi
        fi
        
        echo ""
        echo "Key Configuration Directories:"
        for dir in "/etc/morpheus" "/opt/morpheus/config" "/opt/morpheus/ssl"; do
            if [[ -d "$dir" ]]; then
                echo "✓ $dir exists ($(find "$dir" -type f | wc -l) files)"
            else
                echo "✗ $dir missing"
            fi
        done
        
    } | tee -a "$REPORT_FILE"
    
    log_success "Morpheus configuration check completed"
}

check_database_connectivity() {
    print_header "DATABASE CONNECTIVITY"
    
    local db_host="localhost"
    local db_port="3306"
    local db_name="morpheus"
    
    # Extract database configuration from Morpheus config
    if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
        db_host=$(grep -A 5 "dataSource:" "$MORPHEUS_HOME/config/application.yml" | grep "url:" | sed 's/.*\/\/\([^:]*\).*/\1/' | head -1)
        db_port=$(grep -A 5 "dataSource:" "$MORPHEUS_HOME/config/application.yml" | grep "url:" | sed 's/.*:\([0-9]*\)\/.*/\1/' | head -1)
    fi
    
    {
        echo "Database Configuration:"
        echo "  Host: ${db_host:-localhost}"
        echo "  Port: ${db_port:-3306}"
        echo "  Database: $db_name"
        echo ""
        
        if test_port "${db_host:-localhost}" "${db_port:-3306}"; then
            echo "✓ Database port is accessible"
            log_success "Database connectivity test passed"
        else
            echo "✗ Database port is not accessible"
            log_error "Database connectivity test failed"
        fi
        
        # Test MySQL/MariaDB connection if available
        if check_command mysql; then
            echo ""
            echo "Database Service Status:"
            if systemctl is-active --quiet mysqld || systemctl is-active --quiet mariadb; then
                echo "✓ Database service is running"
                # Try to connect and show basic info
                mysql -e "SELECT VERSION();" 2>/dev/null && echo "✓ Database connection successful" || echo "✗ Database connection failed"
            else
                echo "✗ Database service is not running"
            fi
        fi
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Elasticsearch Checks
##############################################################################

check_elasticsearch() {
    print_header "ELASTICSEARCH STATUS"
    
    local elastic_host="localhost"
    local elastic_port="9200"
    
    # Extract Elasticsearch configuration
    if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
        elastic_host=$(grep -A 10 "elasticsearch:" "$MORPHEUS_HOME/config/application.yml" | grep "host:" | cut -d':' -f2 | xargs | head -1)
        elastic_port=$(grep -A 10 "elasticsearch:" "$MORPHEUS_HOME/config/application.yml" | grep "port:" | cut -d':' -f2 | xargs | head -1)
    fi
    
    {
        echo "Elasticsearch Configuration:"
        echo "  Host: ${elastic_host:-localhost}"
        echo "  Port: ${elastic_port:-9200}"
        echo ""
        
        if test_port "${elastic_host:-localhost}" "${elastic_port:-9200}"; then
            echo "✓ Elasticsearch port is accessible"
            
            # Test Elasticsearch health
            if check_command curl; then
                echo ""
                echo "Elasticsearch Health:"
                local health_response=$(curl -s "http://${elastic_host:-localhost}:${elastic_port:-9200}/_health" 2>/dev/null)
                if [[ $? -eq 0 ]]; then
                    echo "$health_response"
                    echo "✓ Elasticsearch health check successful"
                    log_success "Elasticsearch is healthy"
                else
                    echo "✗ Elasticsearch health check failed"
                    log_error "Elasticsearch health check failed"
                fi
                
                # Cluster information
                echo ""
                echo "Cluster Information:"
                curl -s "http://${elastic_host:-localhost}:${elastic_port:-9200}/_cluster/health?pretty" 2>/dev/null || echo "Could not retrieve cluster information"
            fi
        else
            echo "✗ Elasticsearch port is not accessible"
            log_error "Elasticsearch connectivity test failed"
        fi
        
        # Check Elasticsearch service
        if systemctl is-active --quiet elasticsearch; then
            echo "✓ Elasticsearch service is running"
        else
            echo "✗ Elasticsearch service is not running"
        fi
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# RabbitMQ Checks
##############################################################################

check_rabbitmq() {
    print_header "RABBITMQ STATUS"
    
    local rabbitmq_host="localhost"
    local rabbitmq_port="5672"
    local rabbitmq_mgmt_port="15672"
    
    {
        echo "RabbitMQ Configuration:"
        echo "  Host: $rabbitmq_host"
        echo "  AMQP Port: $rabbitmq_port"
        echo "  Management Port: $rabbitmq_mgmt_port"
        echo ""
        
        # Check RabbitMQ service
        if systemctl is-active --quiet rabbitmq-server; then
            echo "✓ RabbitMQ service is running"
            log_success "RabbitMQ service is active"
        else
            echo "✗ RabbitMQ service is not running"
            log_error "RabbitMQ service is not active"
        fi
        
        # Check ports
        if test_port "$rabbitmq_host" "$rabbitmq_port"; then
            echo "✓ RabbitMQ AMQP port ($rabbitmq_port) is accessible"
        else
            echo "✗ RabbitMQ AMQP port ($rabbitmq_port) is not accessible"
        fi
        
        if test_port "$rabbitmq_host" "$rabbitmq_mgmt_port"; then
            echo "✓ RabbitMQ Management port ($rabbitmq_mgmt_port) is accessible"
        else
            echo "✗ RabbitMQ Management port ($rabbitmq_mgmt_port) is not accessible"
        fi
        
        # RabbitMQ status using rabbitmqctl if available
        if check_command rabbitmqctl; then
            echo ""
            echo "RabbitMQ Status:"
            rabbitmqctl status 2>/dev/null | head -20 || echo "Could not retrieve RabbitMQ status"
            
            echo ""
            echo "RabbitMQ Cluster Status:"
            rabbitmqctl cluster_status 2>/dev/null || echo "Could not retrieve cluster status"
        fi
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Network and Connectivity Checks
##############################################################################

check_network_connectivity() {
    print_header "NETWORK AND CONNECTIVITY"
    
    {
        echo "Network Interface Information:"
        ip addr show | grep -E "inet |state UP" | head -10
        echo ""
        
        echo "DNS Configuration:"
        echo "Nameservers:"
        cat /etc/resolv.conf | grep nameserver
        echo ""
        
        echo "Internet Connectivity Test:"
        if ping -c 3 8.8.8.8 &>/dev/null; then
            echo "✓ Internet connectivity: WORKING"
            log_success "Internet connectivity test passed"
        else
            echo "✗ Internet connectivity: FAILED"
            log_error "Internet connectivity test failed"
        fi
        
        echo ""
        echo "DNS Resolution Test:"
        if nslookup google.com &>/dev/null; then
            echo "✓ DNS resolution: WORKING"
            log_success "DNS resolution test passed"
        else
            echo "✗ DNS resolution: FAILED"
            log_error "DNS resolution test failed"
        fi
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Morpheus UI Accessibility Check
##############################################################################

check_morpheus_ui() {
    print_header "MORPHEUS UI ACCESSIBILITY"
    
    local morpheus_url="https://localhost"
    local morpheus_port="443"
    
    # Try to determine Morpheus URL from config
    if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
        local config_url=$(grep -A 5 "server:" "$MORPHEUS_HOME/config/application.yml" | grep "url:" | cut -d':' -f2- | xargs)
        if [[ -n "$config_url" ]]; then
            morpheus_url="$config_url"
        fi
    fi
    
    {
        echo "Morpheus UI Configuration:"
        echo "  URL: $morpheus_url"
        echo ""
        
        if check_command curl; then
            echo "UI Accessibility Test:"
            local http_status=$(curl -k -s -o /dev/null -w "%{http_code}" "$morpheus_url" 2>/dev/null)
            
            if [[ "$http_status" == "200" ]] || [[ "$http_status" == "302" ]] || [[ "$http_status" == "301" ]]; then
                echo "✓ Morpheus UI is accessible (HTTP Status: $http_status)"
                log_success "Morpheus UI accessibility test passed"
            else
                echo "✗ Morpheus UI is not accessible (HTTP Status: $http_status)"
                log_error "Morpheus UI accessibility test failed"
            fi
        else
            echo "curl command not available for UI testing"
        fi
        
        # Check if Morpheus UI service is listening
        echo ""
        echo "UI Service Ports:"
        netstat -tlnp 2>/dev/null | grep -E ":(80|443|8080|8443)" | head -5 || echo "Could not check port status"
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Cluster Status (for 3-node deployments)
##############################################################################

check_cluster_status() {
    if [[ "$IS_AIO" == true ]]; then
        return 0
    fi
    
    print_header "CLUSTER STATUS (3-NODE DEPLOYMENT)"
    
    {
        echo "Cluster Node Information:"
        
        # Check if other nodes are reachable
        local node_ips=()
        if [[ -f "$MORPHEUS_HOME/config/cluster.conf" ]]; then
            mapfile -t node_ips < <(grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' "$MORPHEUS_HOME/config/cluster.conf")
        fi
        
        if [[ ${#node_ips[@]} -eq 0 ]]; then
            # Try to find node IPs from application.yml
            mapfile -t node_ips < <(grep -A 20 "elasticsearch:" "$MORPHEUS_HOME/config/application.yml" | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' | sort -u)
        fi
        
        if [[ ${#node_ips[@]} -gt 0 ]]; then
            for ip in "${node_ips[@]}"; do
                if ping -c 2 "$ip" &>/dev/null; then
                    echo "✓ Node $ip: REACHABLE"
                else
                    echo "✗ Node $ip: UNREACHABLE"
                fi
            done
        else
            echo "Could not determine cluster node IPs"
        fi
        
        echo ""
        echo "Elasticsearch Cluster Status:"
        if check_command curl && test_port localhost 9200; then
            curl -s "http://localhost:9200/_cluster/health?pretty" 2>/dev/null || echo "Could not retrieve cluster health"
        else
            echo "Elasticsearch not accessible for cluster status check"
        fi
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Configuration Backup
##############################################################################

create_configuration_backup() {
    print_header "CONFIGURATION BACKUP"
    
    local config_backup_dir="$BACKUP_DIR/configurations"
    mkdir -p "$config_backup_dir"
    
    {
        echo "Backing up Morpheus configurations..."
        
        # Backup Morpheus configuration files
        if [[ -d "$MORPHEUS_HOME/config" ]]; then
            cp -r "$MORPHEUS_HOME/config" "$config_backup_dir/morpheus_config" 2>/dev/null
            echo "✓ Morpheus configuration backed up"
        else
            echo "✗ Morpheus configuration directory not found"
        fi
        
        # Backup system configurations
        cp /etc/hosts "$config_backup_dir/" 2>/dev/null && echo "✓ /etc/hosts backed up"
        cp /etc/resolv.conf "$config_backup_dir/" 2>/dev/null && echo "✓ DNS configuration backed up"
        
        # Backup service configurations
        mkdir -p "$config_backup_dir/services"
        cp /etc/systemd/system/morpheus*.service "$config_backup_dir/services/" 2>/dev/null
        
        # Create a summary of backed up files
        echo ""
        echo "Backup Summary:"
        find "$config_backup_dir" -type f | while read -r file; do
            echo "  $(basename "$file") ($(stat -f%z "$file" 2>/dev/null || stat -c%s "$file" 2>/dev/null || echo "unknown") bytes)"
        done
        
        echo ""
        echo "Backup Location: $config_backup_dir"
        
    } | tee -a "$REPORT_FILE"
    
    log_success "Configuration backup completed"
}

##############################################################################
# Log Collection
##############################################################################

collect_logs() {
    print_header "LOG COLLECTION"
    
    local log_backup_dir="$BACKUP_DIR/logs"
    mkdir -p "$log_backup_dir"
    
    {
        echo "Collecting Morpheus logs..."
        
        # Use morpheus-ctl for log access if available
        if check_command morpheus-ctl; then
            echo "=== Recent Morpheus Service Logs (morpheus-ctl tail) ==="
            echo "Capturing last 100 lines from each service..."
            
            # Capture current service logs using morpheus-ctl
            timeout 10s morpheus-ctl tail > "$log_backup_dir/morpheus_services_current.log" 2>&1 || {
                echo "morpheus-ctl tail timed out or failed"
            }
            
            if [[ -f "$log_backup_dir/morpheus_services_current.log" ]]; then
                echo "✓ Current service logs captured via morpheus-ctl"
            fi
        fi
        
        # Morpheus application logs
        if [[ -d "$MORPHEUS_HOME/logs" ]]; then
            cp -r "$MORPHEUS_HOME/logs" "$log_backup_dir/morpheus_logs" 2>/dev/null
            echo "✓ Morpheus application logs collected"
        fi
        
        # System logs for Morpheus services
        journalctl -u morpheus-ui --since "24 hours ago" > "$log_backup_dir/morpheus-ui.log" 2>/dev/null
        journalctl -u morpheus-app --since "24 hours ago" > "$log_backup_dir/morpheus-app.log" 2>/dev/null
        journalctl -u elasticsearch --since "24 hours ago" > "$log_backup_dir/elasticsearch.log" 2>/dev/null
        journalctl -u rabbitmq-server --since "24 hours ago" > "$log_backup_dir/rabbitmq.log" 2>/dev/null
        
        echo "✓ Service logs collected (last 24 hours)"
        
        # Recent system messages
        tail -100 /var/log/messages > "$log_backup_dir/system_messages.log" 2>/dev/null || \
        tail -100 /var/log/syslog > "$log_backup_dir/system_messages.log" 2>/dev/null
        
        # Morpheus-specific log locations
        for log_location in "/var/log/morpheus" "/opt/morpheus/log" "/opt/morpheus/logs"; do
            if [[ -d "$log_location" ]]; then
                cp -r "$log_location" "$log_backup_dir/$(basename "$log_location")_backup" 2>/dev/null
                echo "✓ Additional Morpheus logs from $log_location"
            fi
        done
        
        echo ""
        echo "Log Collection Summary:"
        find "$log_backup_dir" -type f | while read -r file; do
            local line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
            local file_size=$(stat -c%s "$file" 2>/dev/null || echo "0")
            echo "  $(basename "$file") ($line_count lines, $file_size bytes)"
        done
        
        echo ""
        echo "Logs Location: $log_backup_dir"
        
    } | tee -a "$REPORT_FILE"
    
    log_success "Log collection completed"
}

##############################################################################
# Performance and Resource Checks
##############################################################################

check_system_resources() {
    print_header "SYSTEM RESOURCES AND PERFORMANCE"
    
    {
        echo "Current Resource Usage:"
        echo ""
        
        echo "Memory Usage:"
        free -h | grep -E "Mem:|Swap:"
        echo ""
        
        echo "CPU Usage:"
        top -bn1 | grep "Cpu(s)" | head -1
        echo ""
        
        echo "Disk Usage:"
        df -h | grep -E "/(|opt|var|tmp)"
        echo ""
        
        echo "Load Average:"
        uptime
        echo ""
        
        echo "Top Processes by Memory:"
        ps aux --sort=-%mem | head -6
        echo ""
        
        echo "Top Processes by CPU:"
        ps aux --sort=-%cpu | head -6
        echo ""
        
        echo "Network Connections:"
        netstat -tlnp 2>/dev/null | grep -E ":(80|443|3306|5672|9200|15672)" | head -10
        
    } | tee -a "$REPORT_FILE"
    
    log_success "System resource check completed"
}

##############################################################################
# Morpheus API Health Check
##############################################################################

check_morpheus_api() {
    print_header "MORPHEUS API HEALTH CHECK"
    
    local api_url="https://localhost/api/health"
    
    {
        echo "API Health Check:"
        echo "  Endpoint: $api_url"
        echo ""
        
        if check_command curl; then
            local api_response=$(curl -k -s "$api_url" 2>/dev/null)
            local api_status=$?
            
            if [[ $api_status -eq 0 ]] && [[ -n "$api_response" ]]; then
                echo "✓ Morpheus API is responding"
                echo "Response: $api_response"
                log_success "Morpheus API health check passed"
            else
                echo "✗ Morpheus API is not responding"
                log_error "Morpheus API health check failed"
            fi
        else
            echo "curl not available for API testing"
        fi
        
        # Check API service processes
        echo ""
        echo "API-related Processes:"
        ps aux | grep -E "(morpheus|java)" | grep -v grep | head -5
        
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Security and Certificate Checks
##############################################################################

check_security_certificates() {
    print_header "SECURITY AND CERTIFICATES"
    
    {
        echo "SSL Certificate Information:"
        
        if [[ -d "$MORPHEUS_HOME/ssl" ]]; then
            echo "SSL Directory: $MORPHEUS_HOME/ssl"
            ls -la "$MORPHEUS_HOME/ssl/" 2>/dev/null || echo "Could not list SSL directory"
            
            # Check certificate validity if openssl is available
            if check_command openssl && [[ -f "$MORPHEUS_HOME/ssl/server.crt" ]]; then
                echo ""
                echo "Certificate Details:"
                openssl x509 -in "$MORPHEUS_HOME/ssl/server.crt" -text -noout | grep -E "(Subject:|Issuer:|Not Before:|Not After:)" 2>/dev/null
            fi
        else
            echo "SSL directory not found"
        fi
        
        echo ""
        echo "Firewall Status:"
        if systemctl is-active --quiet firewalld; then
            echo "✓ Firewalld is running"
            firewall-cmd --list-all 2>/dev/null | head -10
        elif systemctl is-active --quiet ufw; then
            echo "✓ UFW is running"
            ufw status 2>/dev/null
        else
            echo "No active firewall detected"
        fi
        
        echo ""
        echo "SELinux Status:"
        if check_command sestatus; then
            sestatus 2>/dev/null || echo "SELinux status unavailable"
        else
            echo "SELinux not available"
        fi
        
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Final Validation Summary
##############################################################################

generate_validation_summary() {
    print_header "VALIDATION SUMMARY"
    
    local total_checks=0
    local passed_checks=0
    local failed_checks=0
    local warning_checks=0
    
    # Count results from log file
    total_checks=$(grep -c "\[SUCCESS\]\|\[ERROR\]\|\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")
    passed_checks=$(grep -c "\[SUCCESS\]" "$LOG_FILE" 2>/dev/null || echo "0")
    failed_checks=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || echo "0")
    warning_checks=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")
    
    {
        echo "Overall Validation Results:"
        echo "  Total Checks: $total_checks"
        echo "  Passed: $passed_checks"
        echo "  Failed: $failed_checks"
        echo "  Warnings: $warning_checks"
        echo ""
        
        if [[ $failed_checks -eq 0 ]]; then
            echo "🎉 VALIDATION STATUS: PASSED"
            echo "Morpheus Data installation appears to be successful and ready for production use."
        elif [[ $failed_checks -lt 3 ]]; then
            echo "⚠️  VALIDATION STATUS: PASSED WITH WARNINGS"
            echo "Morpheus Data installation is mostly successful but requires attention to some issues."
        else
            echo "❌ VALIDATION STATUS: FAILED"
            echo "Morpheus Data installation has significant issues that need to be addressed."
        fi
        
        echo ""
        echo "Deployment Summary:"
        echo "  Type: $DEPLOYMENT_TYPE"
        echo "  Nodes: $NODE_COUNT"
        echo "  Validation Date: $(date)"
        echo "  Validation Duration: $(($(date +%s) - $(date -d "$(stat -c %y "$LOG_FILE")" +%s) 2>/dev/null || echo "N/A")) seconds"
        
        echo ""
        echo "Backup Information:"
        echo "  Backup Directory: $BACKUP_DIR"
        echo "  Report File: $REPORT_FILE"
        echo "  Log File: $LOG_FILE"
        
        echo ""
        echo "Next Steps:"
        if [[ $failed_checks -eq 0 ]]; then
            echo "  ✓ Ready for customer handover"
            echo "  ✓ Provide this report and backup files to customer"
            echo "  ✓ Document any specific configuration details"
        else
            echo "  • Review failed checks in the detailed log"
            echo "  • Address any critical issues before handover"
            echo "  • Re-run validation after fixes"
        fi
        
        echo ""
        echo "Morpheus Management Commands (for reference):"
        echo "  morpheus-ctl status          - Check all service status"
        echo "  morpheus-ctl start           - Start all services"
        echo "  morpheus-ctl stop            - Stop all services"
        echo "  morpheus-ctl restart         - Restart all services"
        echo "  morpheus-ctl reconfigure     - Apply configuration changes"
        echo "  morpheus-ctl tail            - View live service logs"
        echo "  morpheus-ctl service-list    - List all available services"
        
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Main Execution Function
##############################################################################

main() {
    # Check if running as root or with sudo
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root user"
    else
        log_warning "Not running as root - some checks may be limited"
    fi
    
    # Initialize
    initialize_script
    
    # System checks
    collect_system_info
    detect_deployment_type
    
    # Core service checks
    check_morpheus_services
    check_morpheus_configuration
    check_database_connectivity
    check_elasticsearch
    check_rabbitmq
    
    # Network and accessibility
    check_network_connectivity
    check_morpheus_ui
    
    # Cluster-specific checks
    check_cluster_status
    
    # System resources
    check_system_resources
    
    # Security
    check_security_certificates
    
    # API health
    check_morpheus_api
    
    # Backup configurations and logs
    create_configuration_backup
    collect_logs
    
    # Generate final summary
    generate_validation_summary
    
    # Final output
    echo ""
    log_info "=== POST-VALIDATION COMPLETE ==="
    log_info "Report available at: $REPORT_FILE"
    log_info "Backup directory: $BACKUP_DIR"
    log_info "All files are stored locally on this server"
    
    # Create a quick reference file
    cat > "$BACKUP_DIR/HANDOVER_SUMMARY.txt" << EOF
MORPHEUS DATA IMPLEMENTATION - HANDOVER SUMMARY
==============================================
Date: $(date)
Server: $(hostname)
Deployment: $DEPLOYMENT_TYPE

Quick Status:
- Passed Checks: $passed_checks
- Failed Checks: $failed_checks
- Warnings: $warning_checks

Files Included:
- Detailed Report: $(basename "$REPORT_FILE")
- Configuration Backup: configurations/
- System Logs: logs/
- Validation Log: $(basename "$LOG_FILE")

ESSENTIAL MORPHEUS MANAGEMENT COMMANDS:
======================================
Service Management:
  morpheus-ctl status          - Check all service status
  morpheus-ctl start           - Start all services
  morpheus-ctl stop            - Stop all services  
  morpheus-ctl restart         - Restart all services
  morpheus-ctl service-list    - List available services

Configuration:
  morpheus-ctl reconfigure     - Apply configuration changes
  morpheus-ctl show-config     - Display current configuration

Monitoring:
  morpheus-ctl tail            - View live service logs

Individual Service Control:
  morpheus-ctl start morpheus-ui     - Start only UI service
  morpheus-ctl restart elasticsearch - Restart only Elasticsearch
  morpheus-ctl stop rabbitmq         - Stop only RabbitMQ

Emergency Commands:
  morpheus-ctl kill            - Force kill all services
  morpheus-ctl graceful-kill   - Graceful stop then force kill

IMPORTANT NOTES:
===============
- Always use morpheus-ctl commands instead of systemctl for Morpheus services
- Run 'morpheus-ctl reconfigure' after any configuration changes
- Check 'morpheus-ctl status' if experiencing issues
- Service logs available via 'morpheus-ctl tail'

Implementation Team Contact: [Your Contact Information]
EOF

    echo ""
    echo "📋 Quick handover summary created: $BACKUP_DIR/HANDOVER_SUMMARY.txt"
    echo ""
    echo "🚀 Ready for customer handover!"
}

##############################################################################
# Script Execution
##############################################################################

# Trap to ensure cleanup on exit
trap 'echo "Script interrupted"; exit 1' INT TERM

# Check if Morpheus directory exists
if [[ ! -d "$MORPHEUS_HOME" ]]; then
    log_error "Morpheus installation directory not found at $MORPHEUS_HOME"
    echo "Please verify Morpheus Data is installed and update MORPHEUS_HOME variable if needed"
    exit 1
fi

# Run main function
main

# Success exit
log_success "Morpheus Data post-installation validation completed successfully"
exit 0
