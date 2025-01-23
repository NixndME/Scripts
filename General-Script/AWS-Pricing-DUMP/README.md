# AWS EC2 Pricing to Morpheus Data Sync

This script fetches AWS EC2 pricing data and formats it for Morpheus Data integration.

## Prerequisites

- Python 3.7+
- AWS CLI configured with appropriate credentials
- Access to Morpheus API


Use the helper script to push to Morpheus:

```
import requests

def push_to_morpheus(pricing_file, morpheus_url, api_key):
    headers = {
        'Authorization': f'Bearer {api_key}',
        'Content-Type': 'application/json'
    }
    
    with open(pricing_file) as f:
        price_sets = json.load(f)
    
    for price_set in price_sets:
        response = requests.post(
            f"{morpheus_url}/api/price-sets",
            headers=headers,
            json=price_set
        )
        print(f"Pushed {price_set['priceSet']['name']}: {response.status_code}")
```

# Example usage
```
push_to_morpheus(
    'aws_all_pricing.json',
    'https://your-morpheus-instance.com',
    'your-api-key'
)
```

# Output Format
The script generates a JSON file with pricing data structured for Morpheus:

```
{
  "priceSet": {
    "name": "Amazon - {instance_type} - {region}",
    "code": "amazon.{instance_type}.{region}",
    "prices": [
      {
        "name": "Amazon - EBS (type) - {region}",
        "priceType": "storage",
        "price": 0.00
      },
      {
        "name": "Amazon - {instance_type} - {region} - {os}",
        "priceType": "compute",
        "price": 0.00
      }
    ]
  }
}

```

# Troubleshooting

AWS Credentials: Ensure AWS CLI is configured with correct credentials
Rate Limits: Script uses pagination to handle AWS API limits
Morpheus API: Check API key permissions if push fails