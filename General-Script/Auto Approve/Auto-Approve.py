#!/usr/bin/env python3

import os
import sys
import json
from datetime import datetime
import time
import subprocess
import warnings

# Check for required libraries
try:
    import requests
    from requests.packages.urllib3.exceptions import InsecureRequestWarning
except ImportError:
    print("The 'requests' library is not installed. Attempting to install it...")
    try:
        subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])
        import requests
        from requests.packages.urllib3.exceptions import InsecureRequestWarning
    except Exception as e:
        print(f"Failed to install 'requests': {e}")
        print("Please install the 'requests' library manually or contact your system administrator.")
        sys.exit(1)

# Disable SSL warnings
warnings.simplefilter('ignore', InsecureRequestWarning)

# Configuration variables
API_KEY = "<%=cypher.read('secret/auto_approve')%>" # API Key
MORPHEUS_URL = "https://morpheus.nixndme.com" # Morphues URL
START_TIME = "18:00"  # 6 PM IST
END_TIME = "22:00"    # 10 PM IST
TIME_ZONE = "Asia/Kolkata"  # IST

def is_within_time_range(current_time, start_time, end_time):
    if start_time <= end_time:
        return start_time <= current_time < end_time
    else:  # Over midnight
        return current_time >= start_time or current_time < end_time

def get_pending_approvals():
    url = f"{MORPHEUS_URL}/api/approvals"
    headers = {
        "Authorization": f"BEARER {API_KEY}",
        "Content-Type": "application/json"
    }
    params = {
        "status": "requested"
    }
    try:
        response = requests.get(url, headers=headers, params=params, verify=False)
        response.raise_for_status()
        return response.json()["approvals"]
    except requests.RequestException as e:
        print(f"Error fetching approvals: {e}")
        print(f"Response content: {response.content if 'response' in locals() else 'No response'}")
        return []

def get_approval_details(approval_id):
    url = f"{MORPHEUS_URL}/api/approvals/{approval_id}"
    headers = {
        "Authorization": f"BEARER {API_KEY}",
        "Content-Type": "application/json"
    }
    try:
        response = requests.get(url, headers=headers, verify=False)
        response.raise_for_status()
        return response.json()["approval"]
    except requests.RequestException as e:
        print(f"Error fetching approval details: {e}")
        print(f"Response content: {response.content if 'response' in locals() else 'No response'}")
        return None

def approve_request(approval_item_id):
    url = f"{MORPHEUS_URL}/api/approval-items/{approval_item_id}/approve"
    headers = {
        "Authorization": f"BEARER {API_KEY}",
        "Content-Type": "application/json"
    }
    try:
        response = requests.put(url, headers=headers, verify=False)
        response.raise_for_status()
        if response.json().get("success"):
            print(f"Successfully approved request item {approval_item_id}")
            return True
        else:
            print(f"Error approving request item {approval_item_id}: Unexpected response")
            print(f"Response content: {response.content}")
            return False
    except requests.RequestException as e:
        print(f"Error approving request item {approval_item_id}: {e}")
        print(f"Response content: {response.content if 'response' in locals() else 'No response'}")
        return False

def main():
    # Set the timezone
    os.environ['TZ'] = TIME_ZONE
    try:
        time.tzset()
    except AttributeError:
        print("Warning: Unable to set timezone. Time-based functions may be inaccurate.")

    current_time = datetime.now().strftime("%H:%M")
    print(f"Current time: {current_time}")
    
    if is_within_time_range(current_time, START_TIME, END_TIME):
        print("Within auto-approval hours. Checking for pending approvals...")
        pending_approvals = get_pending_approvals()
        print(f"Found {len(pending_approvals)} pending approval(s)")
        
        for approval in pending_approvals:
            print(f"Processing approval: {approval['name']} (ID: {approval['id']})")
            approval_details = get_approval_details(approval["id"])
            
            if approval_details:
                approval_items = approval_details.get("approvalItems", [])
                print(f"Approval has {len(approval_items)} item(s)")
                
                for item in approval_items:
                    if item["status"] == "requested":
                        if approve_request(item["id"]):
                            print(f"Approved item {item['id']} for approval {approval['id']}")
                        else:
                            print(f"Failed to approve item {item['id']} for approval {approval['id']}")
            else:
                print(f"Could not fetch details for approval {approval['id']}")
    else:
        print("Outside of auto-approval hours. No action taken.")

if __name__ == "__main__":
    main()
