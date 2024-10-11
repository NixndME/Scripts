!/bin/bash

AWS_REGION="us-east-1"  # Change this to your preferred region

# Get temporary credentials
CREDS=$(aws sts get-session-token --duration-seconds 900)
export AWS_ACCESS_KEY_ID=$(echo $CREDS | jq -r .Credentials.AccessKeyId)
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | jq -r .Credentials.SecretAccessKey)
export AWS_SESSION_TOKEN=$(echo $CREDS | jq -r .Credentials.SessionToken)

# Debug: Print the first few characters of each credential
echo "Debug: AWS_ACCESS_KEY_ID=${AWS_ACCESS_KEY_ID:0:5}..." >&2
echo "Debug: AWS_SECRET_ACCESS_KEY=${AWS_SECRET_ACCESS_KEY:0:5}..." >&2
echo "Debug: AWS_SESSION_TOKEN=${AWS_SESSION_TOKEN:0:10}..." >&2

# Make the request and output JSON
aws rds describe-db-engine-versions \
    --region $AWS_REGION \
    --query 'DBEngineVersions[].{Engine:Engine,EngineVersion:EngineVersion}' \
    --output json

# Unset the environment variables
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
