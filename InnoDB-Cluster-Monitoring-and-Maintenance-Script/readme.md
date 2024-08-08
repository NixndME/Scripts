# MySQL InnoDB Cluster Monitoring and Maintenance Script

This script provides a set of tools for monitoring and maintaining a MySQL InnoDB Cluster. It offers both interactive and command-line interfaces for various tasks such as viewing disk usage, monitoring cluster health, and cleaning binary logs.

## Features

- View MySQL disk usage
- Monitor InnoDB Cluster health and status
- Clean binary logs
- Interactive menu-driven interface
- Command-line options for automation
- Configurable settings
- Error handling and logging

## Prerequisites

- Bash shell
- MySQL client (`mysql`)
- MySQL Shell (`mysqlsh`)
- System utilities: `df`, `free`, `lscpu`

## Installation

1. Download the script:
   ```
   wget https://github.com/NixndME/Scripts/blob/main/InnoDB-Cluster-Monitoring-and-Maintenance-Script/innodb.sh
   ```

2. Make the script executable:
   ```
   chmod +x mysql_monitor.sh
   ```

3. Create a configuration file at `/etc/mysql_monitor_config.sh` with the following content:
   ```bash
   MYSQL_USER="your_mysql_user"
   MYSQL_PASSWORD="your_mysql_password"
   MYSQL_HOST="your_mysql_host"
   BIN_LOG_RETENTION_DAYS=7
   ```
   Adjust the values according to your MySQL setup.

## Usage

### Interactive Mode

Run the script without any arguments to enter interactive mode:

```
./innodb.sh
```

This will display a menu with options to perform various tasks.

### Command-line Mode

The script supports the following command-line options:

- `-u` or `--usage`: View MySQL disk usage
- `-s` or `--status`: Monitor cluster health and status
- `-c` or `--clean`: Clean binary logs
- `-h` or `--help`: Display help message

Example:
```
./innodb.sh --status
```

## Logging

The script logs its activities to `/var/log/mysql_monitor.log`. Check this file for script execution history and any errors encountered.

## Customization

You can modify the following variables in the script or the configuration file to customize its behavior:

- `CONFIG_FILE`: Path to the configuration file
- `LOG_FILE`: Path to the log file
- `MYSQL_USER`: MySQL username
- `MYSQL_PASSWORD`: MySQL password
- `MYSQL_HOST`: MySQL host
- `BIN_LOG_RETENTION_DAYS`: Number of days to retain binary logs

## Security Considerations

- Ensure that the configuration file (`/etc/mysql_monitor_config.sh`) has restricted permissions (e.g., `chmod 600`) to protect sensitive information.
- Use a MySQL user with appropriate privileges for the tasks performed by the script.
- Regularly review and update the script and its configuration to maintain security.

## Troubleshooting

If you encounter any issues:

1. Check the log file at `/var/log/mysql_monitor.log` for error messages.
2. Ensure all prerequisites are installed and accessible.
3. Verify that the MySQL credentials in the configuration file are correct.
4. Make sure the script has the necessary permissions to execute and access required resources.

For further assistance, please contact your system administrator or open an issue in the script's repository.
