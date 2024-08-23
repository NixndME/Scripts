#!/bin/bash

# Source the RabbitMQ environment
source /opt/morpheus/embedded/rabbitmq/.profile

# Get cluster status
cluster_status=$(rabbitmqctl cluster_status --formatter json)

# Extract node names and their running status
node_status=$(echo $cluster_status | jq -r '.running_nodes[] | . + ": ONLINE"')

# Check if any nodes are offline
offline_nodes=$(echo $cluster_status | jq -r '.disk_nodes[] as $disk_node | select([$disk_node] - .running_nodes | length > 0) | $disk_node + ": OFFLINE"')

# Combine online and offline nodes
all_status="$node_status"$'\n'"$offline_nodes"

# Print status of each node
echo "$all_status" | sort

# Check if any node is offline
if echo "$all_status" | grep -q "OFFLINE"; then
    exit 1
else
    exit 0
fi
