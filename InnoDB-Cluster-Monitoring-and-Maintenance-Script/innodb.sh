#!/bin/bash

# Configuration
CONFIG_FILE="/etc/mysql_monitor_config.sh"
LOG_FILE="/var/log/mysql_monitor.log"
MYSQL_USER="root"
MYSQL_PASSWORD=""
MYSQL_HOST="localhost"
BIN_LOG_RETENTION_DAYS=7

# Load configuration if exists
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

# Logging function
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

# Error handling function
handle_error() {
    log "ERROR: $1"
    echo "ERROR: $1" >&2
    exit 1
}

# Check for required commands
for cmd in mysql mysqlsh df free lscpu; do
    command -v "$cmd" >/dev/null 2>&1 || handle_error "$cmd is required but not installed."
done

# Function to display server information
display_server_info() {
    echo "========================================"
    echo "Server Information:"
    echo "Hostname: $(hostname)"
    echo "OS: $(uname -s)"
    echo "Kernel Version: $(uname -r)"
    echo "CPU: $(lscpu | grep 'Model name' | cut -f 2 -d ":" | awk '{$1=$1}1')"
    echo "Memory: $(free -h | awk '/^Mem:/ {print $2}')"
    echo "Disk Usage: $(df -h / | awk '/\// {print $(NF-1)}')"
    echo "========================================"
}

# Function to view MySQL usage
view_mysql_usage() {
    echo "MySQL Disk Usage:"
    df -h /var/lib/mysql || handle_error "Failed to get MySQL disk usage"
    echo
    echo "Detailed MySQL Data Directory Information:"
    echo "----------------------------------------"
    du -sh /var/lib/mysql/* | sort -hr
    echo
    echo "Total MySQL Data Directory Size:"
    du -sh /var/lib/mysql
}

# Function to monitor health and status
monitor_health_status() {
    echo "Monitoring InnoDB Cluster Health and Status:"
    echo "--------------------------------------------"
    mysqlsh --uri "${MYSQL_USER}@${MYSQL_HOST}" --password="$MYSQL_PASSWORD" --js -e "
        var cluster = dba.getCluster();
        var status = cluster.status();
        print(JSON.stringify(status, null, 2));
        
        print('\nCluster Topology:');
        status.defaultReplicaSet.topology.forEach(function(instance) {
            print('  ' + instance.address + ' - ' + instance.status + ' - ' + instance.role);
        });
        
        print('\nCluster Variables:');
        var clusterSet = cluster.listClusterSets();
        print(JSON.stringify(clusterSet, null, 2));
    " || handle_error "Failed to get cluster status"
}

# Function to clean bin log
clean_bin_log() {
    echo "Current Binary Log Information:"
    echo "-------------------------------"
    mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -p"$MYSQL_PASSWORD" -e "SHOW BINARY LOGS;" || handle_error "Failed to show binary logs"
    
    echo
    echo "Cleaning Binary Logs older than $BIN_LOG_RETENTION_DAYS days:"
    echo "------------------------------------------------------------"
    PURGE_RESULT=$(mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -p"$MYSQL_PASSWORD" -e "PURGE BINARY LOGS BEFORE DATE_SUB(NOW(), INTERVAL $BIN_LOG_RETENTION_DAYS DAY);" 2>&1)
    
    if [[ $? -eq 0 ]]; then
        echo "Binary logs successfully purged."
    else
        echo "Error occurred while purging binary logs: $PURGE_RESULT"
    fi
    
    echo
    echo "Remaining Binary Logs:"
    echo "---------------------"
    mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -p"$MYSQL_PASSWORD" -e "SHOW BINARY LOGS;" || handle_error "Failed to show remaining binary logs"
    
    echo
    echo "Total size of remaining binary logs:"
    mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -p"$MYSQL_PASSWORD" -e "
        SELECT 
            SUM(File_size) / 1024 / 1024 AS 'Total Size (MB)'
        FROM 
            information_schema.FILES 
        WHERE 
            File_type = 'BINARY LOG';" || handle_error "Failed to calculate total binary log size"
}

# Function to check MySQL connection
check_mysql_connection() {
    if ! mysql -u "$MYSQL_USER" -h "$MYSQL_HOST" -p"$MYSQL_PASSWORD" -e "SELECT 1;" >/dev/null 2>&1; then
        handle_error "Cannot connect to MySQL. Please check your credentials and MySQL status."
    fi
}

# Function to display help
display_help() {
    echo "Usage: $0 [OPTION]"
    echo "MySQL InnoDB Cluster Monitoring and Maintenance Script"
    echo
    echo "Options:"
    echo "  -u, --usage     View MySQL disk usage"
    echo "  -s, --status    Monitor cluster health and status"
    echo "  -c, --clean     Clean binary logs"
    echo "  -h, --help      Display this help message"
    echo
    echo "Without options, the script runs in interactive mode."
}

# Main function for interactive mode
interactive_mode() {
    while true; do
        clear
        display_server_info

        echo "MySQL InnoDB Cluster Monitoring and Maintenance"
        echo "1. View MySQL Disk Usage"
        echo "2. Monitor Health and Status"
        echo "3. Clean Binary Logs"
        echo "Q. Quit"
        echo
        read -p "Enter your choice: " choice

        case $choice in
            1)
                view_mysql_usage
                ;;
            2)
                monitor_health_status
                ;;
            3)
                clean_bin_log
                ;;
            [Qq])
                echo "Exiting..."
                exit 0
                ;;
            *)
                echo "Invalid option. Please try again."
                ;;
        esac

        echo
        read -n 1 -s -r -p "Press any key to continue..."
    done
}

# Main execution
log "Script started"
check_mysql_connection

# Parse command line arguments
if [[ $# -gt 0 ]]; then
    case "$1" in
        -u|--usage)
            view_mysql_usage
            ;;
        -s|--status)
            monitor_health_status
            ;;
        -c|--clean)
            clean_bin_log
            ;;
        -h|--help)
            display_help
            ;;
        *)
            handle_error "Invalid option. Use -h or --help for usage information."
            ;;
    esac
else
    interactive_mode
fi

log "Script completed successfully"