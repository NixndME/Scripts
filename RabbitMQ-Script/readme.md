# RabbitMQ Cluster Status Check Script

## Overview

This bash script checks the status of nodes in a RabbitMQ cluster. It reports whether each node is ONLINE or OFFLINE, making it useful for monitoring the health of a RabbitMQ cluster.

## Purpose

The script is designed to be used with monitoring systems like SolarWinds. It provides a simple way to check if all nodes in a RabbitMQ cluster are operational.

## Requirements

- Bash shell
- RabbitMQ server (with `rabbitmqctl` available)
- `jq` command-line JSON processor

## Installation

1. Save the script to a file, for example, `/opt/scripts/check_rabbitmq_cluster_status.sh`.
2. Make the script executable:
   ```
   chmod +x /opt/scripts/check_rabbitmq_cluster_status.sh
   ```

## Usage

Run the script manually:

```
/opt/scripts/check_rabbitmq_cluster_status.sh
```

## Output

The script will output the status of each node in your RabbitMQ cluster, like this:

```
rabbit@node1: ONLINE
rabbit@node2: ONLINE
rabbit@node3: ONLINE
```

If any node is offline, it will be reported as such:

```
rabbit@node1: ONLINE
rabbit@node2: OFFLINE
rabbit@node3: ONLINE
```

## Exit Codes

- 0: All nodes are online
- 1: At least one node is offline

## Integration with SolarWinds

1. Create a new Custom Script Monitor in SolarWinds.
2. Set the script path to `/opt/scripts/check_rabbitmq_cluster_status.sh`.
3. Configure the monitor to alert based on the script's exit code:
   - Exit code 0 indicates all nodes are online
   - Exit code 1 indicates at least one node is offline

## Notes

- The script sources the RabbitMQ environment from `/opt/morpheus/embedded/rabbitmq/.profile`. Ensure this path is correct for your setup.
- The script uses `jq` to parse JSON output from `rabbitmqctl`. Ensure `jq` is installed on your system.
- This script is designed for use with Morpheus Data environments. Adjust paths if necessary for your specific setup.

## Troubleshooting

If you encounter any issues:

1. Ensure RabbitMQ is running and `rabbitmqctl` is accessible.
2. Verify that `jq` is installed and in your system's PATH.
3. Check that the RabbitMQ environment file exists at the specified path.

For any persistent issues, consult your RabbitMQ server logs or contact your system administrator.
