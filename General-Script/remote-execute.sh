#!/bin/bash
REMOTE_HOST="mvm03.nixndme.com"  
REMOTE_USER="aswath"      
REMOTE_PASS="xxxxxxx"       
REMOTE_COMMAND="whoami"      

# Function to run remote command and display results
run_remote_command() {
    echo "Connecting to $REMOTE_HOST..."

    RESULT=$(sshpass -p "$REMOTE_PASS" ssh -o StrictHostKeyChecking=no "$REMOTE_USER@$REMOTE_HOST" "$REMOTE_COMMAND")
    EXIT_CODE=$?

    echo "Command output:"
    echo "$RESULT"
    echo ""
    echo "Exit code: $EXIT_CODE"

    if [ $EXIT_CODE -eq 0 ]; then
        echo "Command executed successfully."
    else
        echo "Command execution failed."
    fi
}

run_remote_command
