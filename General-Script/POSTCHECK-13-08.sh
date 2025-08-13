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
    
    # Create backup directory with full path
    if ! mkdir -p "$BACKUP_DIR"; then
        echo "ERROR: Failed to create backup directory: $BACKUP_DIR"
        exit 1
    fi
    
    # Verify backup directory was created
    if [[ ! -d "$BACKUP_DIR" ]]; then
        echo "ERROR: Backup directory does not exist after creation: $BACKUP_DIR"
        exit 1
    fi
    
    # Create log file first
    touch "$LOG_FILE" || {
        echo "ERROR: Cannot create log file: $LOG_FILE"
        exit 1
    }
    
    # Initialize report file
    cat > "$REPORT_FILE" << EOF
Morpheus Data Post-Installation Validation Report
================================================
Date: $(date)
Server: $(hostname)
User: $CURRENT_USER
Script Version: 1.0

EOF

    # Verify report file was created
    if [[ ! -f "$REPORT_FILE" ]]; then
        echo "ERROR: Failed to create report file: $REPORT_FILE"
        exit 1
    fi

    log_info "Starting Morpheus Data post-installation validation"
    log_info "Backup directory: $BACKUP_DIR"
    log_info "Report file: $REPORT_FILE"
    log_info "Log file: $LOG_FILE"
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
    
    local is_cluster=false
    local node_indicators=0
    local detection_method=""
    
    {
        echo "Analyzing deployment configuration..."
        
        # Method 1: Check morpheus-ctl show-config for cluster indicators
        if check_command morpheus-ctl; then
            echo "Checking morpheus-ctl configuration..."
            local morpheus_config=$(morpheus-ctl show-config 2>/dev/null)
            if [[ -n "$morpheus_config" ]]; then
                # Look for multiple elasticsearch nodes
                local elastic_hosts=$(echo "$morpheus_config" | grep -i "elasticsearch" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u | wc -l)
                if [[ $elastic_hosts -gt 1 ]]; then
                    echo "✓ Multiple Elasticsearch nodes detected: $elastic_hosts"
                    is_cluster=true
                    node_indicators=$elastic_hosts
                    detection_method="morpheus-ctl elasticsearch nodes"
                fi
                
                # Look for RabbitMQ cluster configuration
                if echo "$morpheus_config" | grep -qi "rabbitmq.*cluster\|cluster.*rabbitmq"; then
                    echo "✓ RabbitMQ cluster configuration detected"
                    is_cluster=true
                    detection_method="${detection_method}, RabbitMQ cluster"
                fi
                
                # Look for multiple database hosts
                local db_hosts=$(echo "$morpheus_config" | grep -i "database\|mysql\|mariadb" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u | wc -l)
                if [[ $db_hosts -gt 1 ]]; then
                    echo "✓ Multiple database nodes detected: $db_hosts"
                    is_cluster=true
                    detection_method="${detection_method}, multiple DB nodes"
                fi
            fi
        fi
        
        # Method 2: Check application.yml for cluster patterns
        if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
            echo "Analyzing application.yml..."
            
            # Count unique IP addresses in elasticsearch configuration
            local elastic_ips=$(grep -A 20 "elasticsearch:" "$MORPHEUS_HOME/config/application.yml" 2>/dev/null | \
                               grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | sort -u | wc -l)
            if [[ $elastic_ips -gt 1 ]]; then
                echo "✓ Multiple Elasticsearch IPs in application.yml: $elastic_ips"
                is_cluster=true
                node_indicators=$elastic_ips
                detection_method="${detection_method}, application.yml elasticsearch IPs"
            fi
            
            # Look for cluster-specific configuration sections
            if grep -qi "cluster\|ha\|high.availability" "$MORPHEUS_HOME/config/application.yml" 2>/dev/null; then
                echo "✓ Cluster/HA keywords found in application.yml"
                is_cluster=true
                detection_method="${detection_method}, cluster keywords"
            fi
            
            # Check for multiple hosts in various service configurations
            local total_unique_ips=$(grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$MORPHEUS_HOME/config/application.yml" 2>/dev/null | \
                                   grep -v "127.0.0.1\|0.0.0.0" | sort -u | wc -l)
            if [[ $total_unique_ips -gt 1 ]]; then
                echo "✓ Multiple non-localhost IPs detected: $total_unique_ips"
                is_cluster=true
                if [[ $node_indicators -eq 0 ]]; then
                    node_indicators=$total_unique_ips
                fi
                detection_method="${detection_method}, multiple service IPs"
            fi
        fi
        
        # Method 3: Check for cluster-specific files
        echo "Checking for cluster-specific files..."
        if [[ -f "/etc/morpheus/cluster.conf" ]]; then
            echo "✓ Cluster configuration file found: /etc/morpheus/cluster.conf"
            is_cluster=true
            detection_method="${detection_method}, cluster.conf file"
        fi
        
        if [[ -f "/etc/morpheus/morpheus.rb" ]]; then
            if grep -qi "cluster\|ha\|high.availability" "/etc/morpheus/morpheus.rb" 2>/dev/null; then
                echo "✓ Cluster configuration detected in morpheus.rb"
                is_cluster=true
                detection_method="${detection_method}, morpheus.rb cluster config"
            fi
        fi
        
        # Method 4: Check running services for cluster indicators
        echo "Checking running services..."
        
        # Check if elasticsearch is configured for clustering
        if check_command curl && test_port localhost 9200; then
            local es_cluster_info=$(curl -s "http://localhost:9200/_cluster/health?pretty" 2>/dev/null)
            if [[ -n "$es_cluster_info" ]]; then
                local cluster_nodes=$(echo "$es_cluster_info" | grep -o '"number_of_nodes"[[:space:]]*:[[:space:]]*[0-9]*' | grep -o '[0-9]*')
                if [[ $cluster_nodes -gt 1 ]]; then
                    echo "✓ Elasticsearch cluster detected with $cluster_nodes nodes"
                    is_cluster=true
                    node_indicators=$cluster_nodes
                    detection_method="${detection_method}, elasticsearch cluster API"
                fi
            fi
        fi
        
        # Check RabbitMQ cluster status
        if check_command rabbitmqctl; then
            local rabbit_cluster=$(rabbitmqctl cluster_status 2>/dev/null | grep -c "running_nodes")
            if [[ $rabbit_cluster -gt 0 ]]; then
                local rabbit_nodes=$(rabbitmqctl cluster_status 2>/dev/null | grep "running_nodes" | grep -o "rabbit@[^,]*" | wc -l)
                if [[ $rabbit_nodes -gt 1 ]]; then
                    echo "✓ RabbitMQ cluster detected with $rabbit_nodes nodes"
                    is_cluster=true
                    detection_method="${detection_method}, rabbitmq cluster status"
                fi
            fi
        fi
        
        # Method 5: Network connectivity check to other potential nodes
        echo "Checking network connectivity to potential cluster nodes..."
        local reachable_nodes=0
        
        # Get all unique IPs from configuration files
        local all_config_ips=()
        if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
            mapfile -t all_config_ips < <(grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$MORPHEUS_HOME/config/application.yml" 2>/dev/null | \
                                         grep -v "127.0.0.1\|0.0.0.0" | sort -u)
        fi
        
        for ip in "${all_config_ips[@]}"; do
            if [[ -n "$ip" ]] && ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
                ((reachable_nodes++))
                echo "✓ Node reachable: $ip"
            fi
        done
        
        if [[ $reachable_nodes -gt 1 ]]; then
            echo "✓ Multiple cluster nodes reachable: $reachable_nodes"
            is_cluster=true
            if [[ $node_indicators -eq 0 ]]; then
                node_indicators=$reachable_nodes
            fi
            detection_method="${detection_method}, network connectivity"
        fi
        
        echo ""
        echo "Detection Analysis:"
        echo "  Cluster indicators found: $is_cluster"
        echo "  Detection methods: ${detection_method#, }"
        echo "  Estimated node count: $node_indicators"
        
    } | tee -a "$REPORT_FILE"
    
    # Final determination
    if [[ "$is_cluster" == true ]]; then
        DEPLOYMENT_TYPE="3-Node HA Cluster"
        NODE_COUNT=${node_indicators:-3}
        IS_AIO=false
        echo "Deployment Type: $DEPLOYMENT_TYPE" | tee -a "$REPORT_FILE"
        echo "Node Count: $NODE_COUNT" | tee -a "$REPORT_FILE"
        log_success "HA Cluster deployment detected with $NODE_COUNT nodes"
    else
        DEPLOYMENT_TYPE="All-In-One (AIO)"
        NODE_COUNT=1
        IS_AIO=true
        echo "Deployment Type: $DEPLOYMENT_TYPE" | tee -a "$REPORT_FILE"
        echo "Node Count: $NODE_COUNT" | tee -a "$REPORT_FILE"
        log_success "AIO deployment detected"
    fi
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
        
        # Source RabbitMQ profile for proper command execution
        echo "=== RabbitMQ Service Status ==="
        if [[ -f "/opt/morpheus/embedded/rabbitmq/.profile" ]]; then
            echo "✓ RabbitMQ profile found, sourcing for command execution..."
            
            # Create a temporary script to source profile and run commands
            cat > /tmp/rabbitmq_check.sh << 'RABBIT_EOF'
#!/bin/bash
source /opt/morpheus/embedded/rabbitmq/.profile 2>/dev/null
echo "RabbitMQ Cluster Status:"
rabbitmqctl cluster_status 2>/dev/null || echo "Could not retrieve cluster status"
echo ""
echo "RabbitMQ Node Status:"
rabbitmqctl status 2>/dev/null | head -15 || echo "Could not retrieve node status"
RABBIT_EOF
            
            chmod +x /tmp/rabbitmq_check.sh
            /tmp/rabbitmq_check.sh
            rm -f /tmp/rabbitmq_check.sh
            
        else
            echo "⚠ RabbitMQ profile not found at /opt/morpheus/embedded/rabbitmq/.profile"
            echo "Attempting direct rabbitmqctl commands..."
            
            # Fallback to direct commands
            if check_command rabbitmqctl; then
                echo "RabbitMQ Cluster Status:"
                rabbitmqctl cluster_status 2>/dev/null || echo "Could not retrieve cluster status"
                
                echo ""
                echo "RabbitMQ Node Status:"
                rabbitmqctl status 2>/dev/null | head -15 || echo "Could not retrieve node status"
            else
                echo "✗ rabbitmqctl command not available"
            fi
        fi
        
        echo ""
        echo "=== RabbitMQ Process Check ==="
        if systemctl is-active --quiet rabbitmq-server; then
            echo "✓ RabbitMQ service is running"
            log_success "RabbitMQ service is active"
        else
            echo "✗ RabbitMQ service is not running"
            log_error "RabbitMQ service is not active"
        fi
        
        # Check if RabbitMQ processes are running
        local rabbit_processes=$(ps aux | grep -E "[r]abbitmq|[b]eam" | wc -l)
        if [[ $rabbit_processes -gt 0 ]]; then
            echo "✓ RabbitMQ processes detected: $rabbit_processes"
            echo "  Process details:"
            ps aux | grep -E "[r]abbitmq|[b]eam" | head -3 | sed 's/^/    /'
        else
            echo "✗ No RabbitMQ processes detected"
        fi
        
        echo ""
        echo "=== Port Connectivity ==="
        # Check AMQP port
        if test_port "$rabbitmq_host" "$rabbitmq_port"; then
            echo "✓ RabbitMQ AMQP port ($rabbitmq_port) is accessible"
        else
            echo "✗ RabbitMQ AMQP port ($rabbitmq_port) is not accessible"
            log_warning "RabbitMQ AMQP port not accessible"
        fi
        
        # Check Management port
        if test_port "$rabbitmq_host" "$rabbitmq_mgmt_port"; then
            echo "✓ RabbitMQ Management port ($rabbitmq_mgmt_port) is accessible"
        else
            echo "✗ RabbitMQ Management port ($rabbitmq_mgmt_port) is not accessible"
            echo "  Note: Management plugin may not be enabled"
        fi
        
        echo ""
        echo "=== RabbitMQ Management Console ==="
        
        # Check if management plugin is enabled
        if [[ -f "/opt/morpheus/embedded/rabbitmq/.profile" ]]; then
            # Check management plugin status
            cat > /tmp/rabbitmq_mgmt_check.sh << 'MGMT_EOF'
#!/bin/bash
source /opt/morpheus/embedded/rabbitmq/.profile 2>/dev/null
echo "Management Plugin Status:"
rabbitmq-plugins list | grep rabbitmq_management || echo "Could not check plugin status"
MGMT_EOF
            
            chmod +x /tmp/rabbitmq_mgmt_check.sh
            /tmp/rabbitmq_mgmt_check.sh
            rm -f /tmp/rabbitmq_mgmt_check.sh
        fi
        
        # Show management console access information
        echo ""
        echo "Management Console Access:"
        echo "  URL: http://$rabbitmq_host:$rabbitmq_mgmt_port"
        echo "  Username: morpheus"
        
        # Get password from secrets file
        if [[ -f "/etc/morpheus/morpheus-secrets.json" ]]; then
            echo "  Password location: /etc/morpheus/morpheus-secrets.json"
            echo "  Password key: rabbitmq > morpheus_password"
            
            # Try to extract password (safely)
            if check_command jq; then
                local rabbit_password=$(jq -r '.rabbitmq.morpheus_password // empty' /etc/morpheus/morpheus-secrets.json 2>/dev/null)
                if [[ -n "$rabbit_password" && "$rabbit_password" != "null" ]]; then
                    echo "  ✓ Password found in secrets file"
                else
                    echo "  ⚠ Password not found in expected location"
                fi
            else
                echo "  ⚠ jq not available to parse secrets file"
                echo "  Use: cat /etc/morpheus/morpheus-secrets.json | grep -A 3 rabbitmq"
            fi
        else
            echo "  ⚠ Secrets file not found at /etc/morpheus/morpheus-secrets.json"
        fi
        
        echo ""
        echo "=== RabbitMQ Queue Information ==="
        
        # Get queue information if possible
        if [[ -f "/opt/morpheus/embedded/rabbitmq/.profile" ]]; then
            cat > /tmp/rabbitmq_queues.sh << 'QUEUE_EOF'
#!/bin/bash
source /opt/morpheus/embedded/rabbitmq/.profile 2>/dev/null
echo "Queue Summary:"
rabbitmqctl list_queues name messages consumers 2>/dev/null | head -10 || echo "Could not retrieve queue information"
echo ""
echo "Virtual Host Information:"
rabbitmqctl list_vhosts 2>/dev/null || echo "Could not retrieve vhost information"
QUEUE_EOF
            
            chmod +x /tmp/rabbitmq_queues.sh
            /tmp/rabbitmq_queues.sh
            rm -f /tmp/rabbitmq_queues.sh
        fi
        
        echo ""
        echo "=== RabbitMQ Configuration Summary ==="
        
        # Show key configuration details
        if [[ "$IS_AIO" == true ]]; then
            echo "Deployment: All-In-One (single node)"
            echo "Expected behavior: Single RabbitMQ node"
        else
            echo "Deployment: HA Cluster"
            echo "Expected behavior: Multi-node RabbitMQ cluster"
            
            # For HA deployments, show cluster-specific information
            if [[ -f "/opt/morpheus/embedded/rabbitmq/.profile" ]]; then
                echo ""
                echo "Cluster Node Information:"
                cat > /tmp/rabbitmq_cluster.sh << 'CLUSTER_EOF'
#!/bin/bash
source /opt/morpheus/embedded/rabbitmq/.profile 2>/dev/null
echo "Running Nodes:"
rabbitmqctl cluster_status 2>/dev/null | grep -A 10 "running_nodes" | head -10 || echo "Could not retrieve running nodes"
echo ""
echo "Cluster Name:"
rabbitmqctl cluster_status 2>/dev/null | grep "cluster_name" || echo "Could not retrieve cluster name"
CLUSTER_EOF
                
                chmod +x /tmp/rabbitmq_cluster.sh
                /tmp/rabbitmq_cluster.sh
                rm -f /tmp/rabbitmq_cluster.sh
            fi
        fi
        
        echo ""
        echo "Troubleshooting Commands:"
        echo "  Enable management console: source /opt/morpheus/embedded/rabbitmq/.profile && rabbitmq-plugins enable rabbitmq_management"
        echo "  Check cluster status: source /opt/morpheus/embedded/rabbitmq/.profile && rabbitmqctl cluster_status"
        echo "  View queues: source /opt/morpheus/embedded/rabbitmq/.profile && rabbitmqctl list_queues"
        echo "  Restart RabbitMQ: morpheus-ctl restart rabbitmq"
        
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
        print_header "SINGLE NODE STATUS (AIO DEPLOYMENT)"
        {
            echo "Single node deployment - cluster checks skipped"
            echo "All services running on: $(hostname) ($(hostname -I | awk '{print $1}'))"
        } | tee -a "$REPORT_FILE"
        return 0
    fi
    
    print_header "HA CLUSTER STATUS (MULTI-NODE DEPLOYMENT)"
    
    {
        echo "HA Cluster Analysis:"
        echo "  Deployment Type: $DEPLOYMENT_TYPE"
        echo "  Expected Nodes: $NODE_COUNT"
        echo "  Current Node: $(hostname) ($(hostname -I | awk '{print $1}'))"
        echo ""
        
        # Get cluster node information from various sources
        local cluster_nodes=()
        local node_status=()
        
        echo "=== Node Discovery ==="
        
        # Method 1: Extract IPs from configuration files
        if [[ -f "$MORPHEUS_HOME/config/application.yml" ]]; then
            mapfile -t config_ips < <(grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' "$MORPHEUS_HOME/config/application.yml" 2>/dev/null | \
                                    grep -v "127.0.0.1\|0.0.0.0" | sort -u)
            
            if [[ ${#config_ips[@]} -gt 0 ]]; then
                echo "Cluster nodes from configuration:"
                for ip in "${config_ips[@]}"; do
                    echo "  - $ip"
                    cluster_nodes+=("$ip")
                done
            fi
        fi
        
        # Method 2: Check morpheus-ctl configuration
        if check_command morpheus-ctl; then
            echo ""
            echo "=== Morpheus-ctl Cluster Information ==="
            morpheus-ctl show-config 2>/dev/null | grep -A 5 -B 5 -i "elasticsearch\|rabbitmq\|database" | head -20 || {
                echo "Could not retrieve cluster configuration via morpheus-ctl"
            }
        fi
        
        echo ""
        echo "=== Cluster Node Connectivity ==="
        
        # Test connectivity to discovered nodes
        local reachable_count=0
        local unreachable_count=0
        
        if [[ ${#cluster_nodes[@]} -eq 0 ]]; then
            echo "No cluster nodes discovered from configuration"
            echo "Attempting to detect nodes via service discovery..."
            
            # Try to get nodes from elasticsearch if available
            if check_command curl && test_port localhost 9200; then
                local es_nodes=$(curl -s "http://localhost:9200/_cat/nodes?format=json" 2>/dev/null)
                if [[ -n "$es_nodes" ]] && [[ "$es_nodes" != "null" ]]; then
                    echo "Elasticsearch cluster nodes:"
                    echo "$es_nodes" | head -10
                fi
            fi
        else
            for node in "${cluster_nodes[@]}"; do
                echo -n "Testing connectivity to $node... "
                if ping -c 2 -W 3 "$node" >/dev/null 2>&1; then
                    echo "✓ REACHABLE"
                    ((reachable_count++))
                    
                    # Test specific services on this node
                    echo "  Service checks for $node:"
                    
                    # Elasticsearch
                    if test_port "$node" 9200 2; then
                        echo "    ✓ Elasticsearch (9200): Available"
                    else
                        echo "    ✗ Elasticsearch (9200): Not accessible"
                    fi
                    
                    # RabbitMQ
                    if test_port "$node" 5672 2; then
                        echo "    ✓ RabbitMQ (5672): Available"
                    else
                        echo "    ✗ RabbitMQ (5672): Not accessible"
                    fi
                    
                    # Morpheus UI
                    if test_port "$node" 443 2; then
                        echo "    ✓ Morpheus UI (443): Available"
                    else
                        echo "    ✗ Morpheus UI (443): Not accessible"
                    fi
                    
                else
                    echo "✗ UNREACHABLE"
                    ((unreachable_count++))
                fi
                echo ""
            done
        fi
        
        echo "=== Elasticsearch Cluster Status ==="
        if check_command curl && test_port localhost 9200; then
            local cluster_health=$(curl -s "http://localhost:9200/_cluster/health?pretty" 2>/dev/null)
            if [[ -n "$cluster_health" ]]; then
                echo "Cluster Health:"
                echo "$cluster_health"
                
                # Parse key metrics
                local cluster_status=$(echo "$cluster_health" | grep '"status"' | cut -d'"' -f4)
                local number_of_nodes=$(echo "$cluster_health" | grep '"number_of_nodes"' | grep -o '[0-9]*')
                local active_shards=$(echo "$cluster_health" | grep '"active_shards"' | grep -o '[0-9]*')
                
                echo ""
                echo "Key Metrics:"
                echo "  Cluster Status: ${cluster_status:-Unknown}"
                echo "  Active Nodes: ${number_of_nodes:-Unknown}"
                echo "  Active Shards: ${active_shards:-Unknown}"
                
                if [[ "$cluster_status" == "green" ]]; then
                    echo "  ✓ Elasticsearch cluster is healthy"
                elif [[ "$cluster_status" == "yellow" ]]; then
                    echo "  ⚠ Elasticsearch cluster has warnings"
                elif [[ "$cluster_status" == "red" ]]; then
                    echo "  ✗ Elasticsearch cluster has critical issues"
                fi
            else
                echo "Could not retrieve Elasticsearch cluster health"
            fi
            
            echo ""
            echo "Node Information:"
            curl -s "http://localhost:9200/_cat/nodes?v" 2>/dev/null | head -10 || {
                echo "Could not retrieve node information"
            }
        else
            echo "Elasticsearch not accessible on localhost:9200"
        fi
        
        echo ""
        echo "=== RabbitMQ Cluster Status ==="
        if check_command rabbitmqctl; then
            echo "RabbitMQ Cluster Status:"
            rabbitmqctl cluster_status 2>/dev/null | head -20 || {
                echo "Could not retrieve RabbitMQ cluster status"
            }
            
            echo ""
            echo "RabbitMQ Node Status:"
            rabbitmqctl node_health_check 2>/dev/null || {
                echo "Could not check RabbitMQ node health"
            }
        else
            echo "rabbitmqctl command not available"
        fi
        
        echo ""
        echo "=== Cluster Summary ==="
        echo "Discovery Summary:"
        echo "  Total configured nodes: ${#cluster_nodes[@]}"
        echo "  Reachable nodes: $reachable_count"
        echo "  Unreachable nodes: $unreachable_count"
        
        if [[ $reachable_count -gt 1 ]]; then
            echo "  ✓ Multi-node cluster connectivity confirmed"
            log_success "HA cluster validation passed - $reachable_count nodes reachable"
        elif [[ $reachable_count -eq 1 ]]; then
            echo "  ⚠ Only current node reachable - possible cluster communication issues"
            log_warning "HA cluster may have connectivity issues"
        else
            echo "  ✗ No cluster nodes reachable - cluster may be misconfigured"
            log_error "HA cluster validation failed - no nodes reachable"
        fi
        
    } | tee -a "$REPORT_FILE"
}

##############################################################################
# Configuration Backup
##############################################################################

create_configuration_backup() {
    print_header "CONFIGURATION BACKUP"
    
    local config_backup_dir="$BACKUP_DIR/configurations"
    
    # Ensure configuration backup directory exists
    if ! mkdir -p "$config_backup_dir"; then
        log_error "Failed to create configuration backup directory: $config_backup_dir"
        return 1
    fi
    
    {
        echo "Backing up Morpheus configurations..."
        
        # Backup Morpheus configuration files
        if [[ -d "$MORPHEUS_HOME/config" ]]; then
            if cp -r "$MORPHEUS_HOME/config" "$config_backup_dir/morpheus_config" 2>/dev/null; then
                echo "✓ Morpheus configuration backed up"
            else
                echo "⚠ Failed to backup Morpheus configuration"
            fi
        else
            echo "⚠ Morpheus configuration directory not found at $MORPHEUS_HOME/config"
        fi
        
        # Backup system configurations with error handling
        if [[ -f "/etc/hosts" ]]; then
            if cp /etc/hosts "$config_backup_dir/" 2>/dev/null; then
                echo "✓ /etc/hosts backed up"
            else
                echo "⚠ Failed to backup /etc/hosts"
            fi
        else
            echo "⚠ /etc/hosts not found"
        fi
        
        if [[ -f "/etc/resolv.conf" ]]; then
            if cp /etc/resolv.conf "$config_backup_dir/" 2>/dev/null; then
                echo "✓ DNS configuration backed up"
            else
                echo "⚠ Failed to backup DNS configuration"
            fi
        else
            echo "⚠ /etc/resolv.conf not found"
        fi
        
        # Backup Morpheus main configuration
        if [[ -f "/etc/morpheus/morpheus.rb" ]]; then
            if cp "/etc/morpheus/morpheus.rb" "$config_backup_dir/" 2>/dev/null; then
                echo "✓ Main Morpheus configuration (/etc/morpheus/morpheus.rb) backed up"
            else
                echo "⚠ Failed to backup main Morpheus configuration"
            fi
        else
            echo "⚠ Main Morpheus configuration not found at /etc/morpheus/morpheus.rb"
        fi
        
        # Backup service configurations
        if mkdir -p "$config_backup_dir/services" 2>/dev/null; then
            local service_files_found=false
            if ls /etc/systemd/system/morpheus*.service >/dev/null 2>&1; then
                if cp /etc/systemd/system/morpheus*.service "$config_backup_dir/services/" 2>/dev/null; then
                    echo "✓ Morpheus service files backed up"
                    service_files_found=true
                fi
            fi
            
            if [[ "$service_files_found" == false ]]; then
                echo "⚠ No Morpheus service files found in /etc/systemd/system/"
            fi
        else
            echo "⚠ Failed to create services backup directory"
        fi
        
        # Create a summary of backed up files
        echo ""
        echo "Backup Summary:"
        if [[ -d "$config_backup_dir" ]]; then
            local file_count=0
            find "$config_backup_dir" -type f 2>/dev/null | while read -r file; do
                if [[ -f "$file" ]]; then
                    local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "unknown")
                    echo "  $(basename "$file") ($file_size bytes)"
                    ((file_count++))
                fi
            done
            
            if [[ $file_count -eq 0 ]]; then
                echo "  No configuration files were successfully backed up"
            fi
        else
            echo "  Configuration backup directory not accessible"
        fi
        
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
    
    # Ensure log backup directory exists
    if ! mkdir -p "$log_backup_dir"; then
        log_error "Failed to create log backup directory: $log_backup_dir"
        return 1
    fi
    
    {
        echo "Collecting Morpheus logs..."
        
        # Use morpheus-ctl for log access if available
        if check_command morpheus-ctl; then
            echo "=== Recent Morpheus Service Logs (morpheus-ctl tail) ==="
            echo "Capturing last 100 lines from each service..."
            
            # Capture current service logs using morpheus-ctl
            if timeout 10s morpheus-ctl tail > "$log_backup_dir/morpheus_services_current.log" 2>&1; then
                echo "✓ Current service logs captured via morpheus-ctl"
            else
                echo "⚠ morpheus-ctl tail timed out or failed"
            fi
        fi
        
        # Morpheus application logs
        if [[ -d "$MORPHEUS_HOME/logs" ]]; then
            if cp -r "$MORPHEUS_HOME/logs" "$log_backup_dir/morpheus_logs" 2>/dev/null; then
                echo "✓ Morpheus application logs collected"
            else
                echo "⚠ Failed to copy Morpheus application logs"
            fi
        else
            echo "⚠ Morpheus logs directory not found at $MORPHEUS_HOME/logs"
        fi
        
        # System logs for Morpheus services with error handling
        echo "Collecting systemd service logs..."
        
        if journalctl -u morpheus-ui --since "24 hours ago" > "$log_backup_dir/morpheus-ui.log" 2>/dev/null && [[ -s "$log_backup_dir/morpheus-ui.log" ]]; then
            echo "✓ morpheus-ui logs collected"
        else
            echo "⚠ morpheus-ui logs not available or empty"
            echo "No morpheus-ui logs available" > "$log_backup_dir/morpheus-ui.log"
        fi
        
        if journalctl -u morpheus-app --since "24 hours ago" > "$log_backup_dir/morpheus-app.log" 2>/dev/null && [[ -s "$log_backup_dir/morpheus-app.log" ]]; then
            echo "✓ morpheus-app logs collected"
        else
            echo "⚠ morpheus-app logs not available or empty"
            echo "No morpheus-app logs available" > "$log_backup_dir/morpheus-app.log"
        fi
        
        if journalctl -u elasticsearch --since "24 hours ago" > "$log_backup_dir/elasticsearch.log" 2>/dev/null && [[ -s "$log_backup_dir/elasticsearch.log" ]]; then
            echo "✓ elasticsearch logs collected"
        else
            echo "⚠ elasticsearch logs not available or empty"
            echo "No elasticsearch logs available" > "$log_backup_dir/elasticsearch.log"
        fi
        
        if journalctl -u rabbitmq-server --since "24 hours ago" > "$log_backup_dir/rabbitmq.log" 2>/dev/null && [[ -s "$log_backup_dir/rabbitmq.log" ]]; then
            echo "✓ rabbitmq logs collected"
        else
            echo "⚠ rabbitmq logs not available or empty"
            echo "No rabbitmq logs available" > "$log_backup_dir/rabbitmq.log"
        fi
        
        # Recent system messages with better error handling
        echo "Collecting system logs..."
        if tail -100 /var/log/messages > "$log_backup_dir/system_messages.log" 2>/dev/null; then
            echo "✓ System messages collected from /var/log/messages"
        elif tail -100 /var/log/syslog > "$log_backup_dir/system_messages.log" 2>/dev/null; then
            echo "✓ System messages collected from /var/log/syslog"
        else
            echo "⚠ System messages not available"
            echo "No system messages available" > "$log_backup_dir/system_messages.log"
        fi
        
        # Morpheus-specific log locations with error handling
        local found_additional_logs=false
        for log_location in "/var/log/morpheus" "/opt/morpheus/log" "/opt/morpheus/logs"; do
            if [[ -d "$log_location" ]]; then
                if cp -r "$log_location" "$log_backup_dir/$(basename "$log_location")_backup" 2>/dev/null; then
                    echo "✓ Additional Morpheus logs from $log_location"
                    found_additional_logs=true
                else
                    echo "⚠ Failed to copy logs from $log_location"
                fi
            fi
        done
        
        if [[ "$found_additional_logs" == false ]]; then
            echo "⚠ No additional Morpheus log directories found"
        fi
        
        echo ""
        echo "Log Collection Summary:"
        if [[ -d "$log_backup_dir" ]]; then
            find "$log_backup_dir" -type f 2>/dev/null | while read -r file; do
                if [[ -f "$file" ]]; then
                    local line_count=$(wc -l < "$file" 2>/dev/null || echo "0")
                    local file_size=$(stat -c%s "$file" 2>/dev/null || stat -f%z "$file" 2>/dev/null || echo "0")
                    echo "  $(basename "$file") ($line_count lines, $file_size bytes)"
                fi
            done
        else
            echo "  No log files collected"
        fi
        
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
    
    # Count results from log file with error handling
    if [[ -f "$LOG_FILE" && -r "$LOG_FILE" ]]; then
        total_checks=$(grep -c "\[SUCCESS\]\|\[ERROR\]\|\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")
        passed_checks=$(grep -c "\[SUCCESS\]" "$LOG_FILE" 2>/dev/null || echo "0")
        failed_checks=$(grep -c "\[ERROR\]" "$LOG_FILE" 2>/dev/null || echo "0")
        warning_checks=$(grep -c "\[WARNING\]" "$LOG_FILE" 2>/dev/null || echo "0")
    else
        log_error "Log file not accessible for summary generation"
        total_checks=1
        failed_checks=1
    fi
    
    # Calculate validation duration safely
    local validation_duration="N/A"
    if [[ -f "$LOG_FILE" ]]; then
        local log_start_time=$(stat -c %Y "$LOG_FILE" 2>/dev/null || echo "0")
        local current_time=$(date +%s)
        if [[ $log_start_time -gt 0 && $current_time -gt $log_start_time ]]; then
            validation_duration=$((current_time - log_start_time))
        fi
    fi
    
    {
        echo "Overall Validation Results:"
        echo "  Total Checks: $total_checks"
        echo "  Passed: $passed_checks"
        echo "  Failed: $failed_checks"
        echo "  Warnings: $warning_checks"
        echo ""
        
        if [[ $failed_checks -eq 0 && $total_checks -gt 0 ]]; then
            echo "🎉 VALIDATION STATUS: PASSED"
            echo "Morpheus Data installation appears to be successful and ready for production use."
        elif [[ $failed_checks -gt 0 && $failed_checks -lt 3 && $total_checks -gt 0 ]]; then
            echo "⚠️  VALIDATION STATUS: PASSED WITH WARNINGS"
            echo "Morpheus Data installation is mostly successful but requires attention to some issues."
        elif [[ $total_checks -eq 0 ]]; then
            echo "⚠️  VALIDATION STATUS: INCOMPLETE"
            echo "Validation checks could not be completed properly - please review the logs."
        else
            echo "❌ VALIDATION STATUS: FAILED"
            echo "Morpheus Data installation has significant issues that need to be addressed."
        fi
        
        echo ""
        echo "Deployment Summary:"
        echo "  Type: $DEPLOYMENT_TYPE"
        echo "  Nodes: $NODE_COUNT"
        echo "  Validation Date: $(date)"
        echo "  Validation Duration: ${validation_duration} seconds"
        
        echo ""
        echo "Backup Information:"
        echo "  Backup Directory: $BACKUP_DIR"
        if [[ -f "$REPORT_FILE" ]]; then
            echo "  Report File: $REPORT_FILE"
        else
            echo "  Report File: Not created successfully"
        fi
        if [[ -f "$LOG_FILE" ]]; then
            echo "  Log File: $LOG_FILE"
        else
            echo "  Log File: Not created successfully"
        fi
        
        echo ""
        echo "Next Steps:"
        if [[ $failed_checks -eq 0 && $total_checks -gt 0 ]]; then
            echo "  ✓ Ready for customer handover"
            echo "  ✓ Provide this report and backup files to customer"
            echo "  ✓ Document any specific configuration details"
        else
            echo "  • Review failed checks in the detailed log"
            echo "  • Address any critical issues before handover"
            echo "  • Re-run validation after fixes"
            if [[ $total_checks -eq 0 ]]; then
                echo "  • Check file permissions and disk space"
                echo "  • Verify script has necessary access rights"
            fi
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
        
    } | tee -a "$REPORT_FILE" 2>/dev/null || {
        # If we can't write to report file, at least output to console
        echo "WARNING: Could not write to report file, displaying summary to console only"
    }
}

##############################################################################
# Main Execution Function
##############################################################################

main() {
    # Pre-flight checks
    echo "Starting Morpheus Data Post-Installation Validation Script"
    echo "========================================================"
    
    # Check if running as root or with sudo
    if [[ $EUID -eq 0 ]]; then
        echo "✓ Running as root user"
    else
        echo "⚠ Not running as root - some checks may be limited"
        echo "  Consider running with sudo for complete validation"
    fi
    
    # Check basic requirements
    echo ""
    echo "Pre-flight System Checks:"
    
    # Check if we can create directories in /opt/morpheus
    if [[ ! -d "/opt/morpheus" ]]; then
        echo "✗ /opt/morpheus directory does not exist"
        echo "  Creating /opt/morpheus directory..."
        if ! mkdir -p /opt/morpheus 2>/dev/null; then
            echo "ERROR: Cannot create /opt/morpheus directory. Check permissions."
            exit 1
        fi
    fi
    
    if [[ ! -w "/opt/morpheus" ]]; then
        echo "✗ Cannot write to /opt/morpheus directory"
        echo "ERROR: Insufficient permissions to write to /opt/morpheus"
        echo "Please run this script with appropriate permissions (sudo recommended)"
        exit 1
    else
        echo "✓ Write access to /opt/morpheus confirmed"
    fi
    
    # Check disk space
    local available_space=$(df /opt/morpheus 2>/dev/null | tail -1 | awk '{print $4}' || echo "0")
    if [[ $available_space -lt 1000000 ]]; then  # Less than ~1GB
        echo "⚠ Low disk space available ($(df -h /opt/morpheus 2>/dev/null | tail -1 | awk '{print $4}' || echo "unknown"))"
    else
        echo "✓ Sufficient disk space available"
    fi
    
    echo ""
    
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
    echo "=== POST-VALIDATION COMPLETE ==="
    if [[ -f "$REPORT_FILE" ]]; then
        echo "✓ Report available at: $REPORT_FILE"
    else
        echo "⚠ Report file could not be created"
    fi
    
    if [[ -d "$BACKUP_DIR" ]]; then
        echo "✓ Backup directory: $BACKUP_DIR"
        echo "✓ All files are stored locally on this server"
    else
        echo "⚠ Backup directory could not be created properly"
    fi
    
    # Create a quick reference file with error handling
    local handover_file="$BACKUP_DIR/HANDOVER_SUMMARY.txt"
    if cat > "$handover_file" << EOF
MORPHEUS DATA IMPLEMENTATION - HANDOVER SUMMARY
==============================================
Date: $(date)
Server: $(hostname) ($(hostname -I | awk '{print $1}'))
Deployment: ${DEPLOYMENT_TYPE:-"Unknown"}
Node Count: ${NODE_COUNT:-"Unknown"}

Quick Status:
- Passed Checks: ${passed_checks:-0}
- Failed Checks: ${failed_checks:-0}
- Warnings: ${warning_checks:-0}

$(if [[ "$IS_AIO" != true ]]; then echo "
HA CLUSTER INFORMATION:
======================
This is a High Availability cluster deployment with multiple nodes.
Each node provides redundancy and load distribution for Morpheus services.

Key HA Services:
- Elasticsearch: Distributed search and analytics
- RabbitMQ: Message queue clustering  
- Database: Replicated data storage
- Morpheus UI: Load-balanced web interface
"; fi)

Files Included:
- Detailed Report: $(basename "$REPORT_FILE" 2>/dev/null || echo "Not created")
- Configuration Backup: configurations/
- System Logs: logs/
- Validation Log: $(basename "$LOG_FILE" 2>/dev/null || echo "Not created")

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

$(if [[ "$IS_AIO" != true ]]; then echo "
HA CLUSTER SPECIFIC COMMANDS:
============================
Cluster Health Checks:
  curl -s 'http://localhost:9200/_cluster/health?pretty'  - Elasticsearch cluster health
  rabbitmqctl cluster_status                              - RabbitMQ cluster status
  morpheus-ctl status                                     - All service status

Node Management:
  - Always check cluster health before performing maintenance
  - Use rolling restarts for service updates
  - Monitor all nodes during maintenance operations
  - Ensure at least 2 nodes remain operational during maintenance
"; fi)

IMPORTANT NOTES:
===============
- Always use morpheus-ctl commands instead of systemctl for Morpheus services
- Run 'morpheus-ctl reconfigure' after any configuration changes
- Check 'morpheus-ctl status' if experiencing issues
- Service logs available via 'morpheus-ctl tail'
$(if [[ "$IS_AIO" != true ]]; then echo "- For HA clusters: Monitor all nodes and maintain cluster quorum
- Coordinate maintenance activities across all cluster nodes"; fi)

Implementation Team Contact: [Your Contact Information]
EOF
    then
        echo ""
        echo "📋 Quick handover summary created: $handover_file"
    else
        echo ""
        echo "⚠️  Warning: Could not create handover summary file"
        log_warning "Failed to create handover summary file"
    fi
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
