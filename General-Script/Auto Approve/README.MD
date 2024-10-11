# Morpheus Auto-Approver Script

This Python script automates the approval process for pending requests in Morpheus during specified off-hours. It's designed to run as a scheduled task within the Morpheus environment.

## How It Works

1. The script checks if the current time is within the specified auto-approval hours.
2. If within the designated time range, it fetches all pending approval requests from Morpheus.
3. For each pending approval, it retrieves the approval details and processes each approval item.
4. If an approval item is in a "requested" status, the script attempts to approve it automatically.

## Setup in Morpheus

1. **Create a Cypher for the API Key:**
   - Go to `Tools > Cypher`
   - Click "+ ADD KEY"
   - Set the Key to "secret/auto_approve"
   - Set the Value to your Morpheus API key
   - Click SAVE

2. **Create a Python Task:**
   - Go to `Library > Automation > Tasks`
   - Click "+ ADD"
   - Set the following:
     - NAME: Auto Approve Off-Hours Requests
     - TYPE: Python Script
     - EXECUTE TARGET: Local
   - Paste the script content into the SCRIPT field
   - Click SAVE

3. **Create a Task Set:**
   - Go to `Library > Automation > Task Sets`
   - Click "+ ADD"
   - Set the NAME to "Auto Approve Off-Hours Requests"
   - In the TASKS section, add the task you just created
   - Click SAVE

4. **Create a Job:**
   - Go to `Jobs > Jobs`
   - Click "+ ADD"
   - Set the following:
     - NAME: Auto Approve Off-Hours Requests
     - JOB TYPE: Task Set Job
     - TASK SET: Select the Task Set you created
     - Execution Schedule: Set to run at your desired frequency
   - Click SAVE

5. **Enable the Job:**
   - In the Jobs list, find your new job
   - Toggle the switch in the ENABLED column to turn it on

## Configuration

Edit the following variables in the script to customize its behavior:

- `API_KEY`: The Cypher key where your Morpheus API key is stored
- `MORPHEUS_URL`: Your Morpheus instance URL
- `START_TIME`: The start time for auto-approvals (24-hour format)
- `END_TIME`: The end time for auto-approvals (24-hour format)
- `TIME_ZONE`: The time zone for the script (default is "Asia/Kolkata")

## When to Use

- Use this script when you want to automate approvals during off-hours or specific time ranges.
- Ideal for environments where quick provisioning is needed outside of business hours.
- Useful for reducing delays in workflows that require approvals.

## When Not to Use

- Don't use this script if all approvals require manual review, regardless of the time of day.
- Avoid using it if your organization's policy prohibits automated approvals.
- Not recommended if you need different approval criteria for different types of requests.

## Security Considerations

- The script currently disables SSL certificate verification. This is not recommended for production environments.
- Ensure that your Morpheus instance has a valid SSL certificate installed for secure communications.
- Regularly rotate your API key and update it in the Morpheus Cypher.
- Review and adjust the auto-approval time window regularly to align with your organization's needs.

## Troubleshooting

- If the script fails to run, check the Morpheus logs for detailed error messages.
- Ensure that the API key has the necessary permissions to view and modify approvals.
- Verify that the Morpheus URL is correct and accessible from the machine running the script.

## Disclaimer

This script is provided as-is. Use it at your own risk and make sure to thoroughly test it in a non-production environment before deploying to production.

## Contributing

Feel free to fork this repository and submit pull requests for any enhancements or bug fixes.
