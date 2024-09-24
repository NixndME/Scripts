# AWS RDS Engine Versions Fetcher

## Purpose

This script fetches and displays all available database engine versions for Amazon RDS (Relational Database Service). It's useful for DevOps engineers, developers integrating RDS instance creation, and system administrators planning database deployments or upgrades.

## Prerequisites

- AWS CLI installed and configured with appropriate credentials
- `jq` command-line JSON processor installed
- Bash shell environment

## Installation and Usage:

1. Save the following script content to a file named `fetch_rds_versions.sh`

## Make the script executable:

chmod +x fetch_rds_versions.sh

## Run Script:

./fetch_rds_versions.sh > rds_versions.json

## View the results:

cat rds_versions.json

## Example output:

[
  {
    "Engine": "aurora-mysql",
    "EngineVersion": "5.7.mysql_aurora.2.11.1"
  },
  {
    "Engine": "mysql",
    "EngineVersion": "8.0.32"
  },
  ...
]


Customization

To change the AWS region, modify the AWS_REGION variable at the beginning of the script.
The script uses temporary credentials for added security. If you prefer to use your default AWS CLI credentials, you can remove the credential generation part of the script.

Security Note
This script generates temporary AWS credentials. Ensure you do not share the debug output or the script while it's populated with sensitive information.
Troubleshooting
If you encounter any issues:

Ensure your AWS CLI is correctly configured with the necessary permissions.
Check that you have the required permissions to describe RDS engine versions.
Verify that jq is installed and accessible in your PATH.

For any persistent issues, please check the AWS CLI documentation or seek support from your AWS administrator.
