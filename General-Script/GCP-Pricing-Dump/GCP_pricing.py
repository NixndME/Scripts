import requests
import json
from typing import List, Dict, Any

class GCPPricingClient:
    def __init__(self, api_key: str):
        self.api_key = api_key
        self.base_url = "https://cloudbilling.googleapis.com/v1"
        
    def get_compute_skus(self, max_pages: int = 10) -> List[Dict[str, Any]]:
        """Get Compute Engine VM SKUs for us-central1"""
        print("Fetching Compute Engine SKUs for us-central1...")
        url = f"{self.base_url}/services/6F81-5844-456A/skus"
        params = {
            'key': self.api_key,
            'pageSize': 100
        }
        skus = []
        page_count = 1
        
        while page_count <= max_pages:
            try:
                print(f"Fetching page {page_count}...")
                response = requests.get(url, params=params)
                response.raise_for_status()
                data = response.json()
                
                # Debug: Print first SKU structure
                if page_count == 1 and data.get('skus'):
                    print("\nExample SKU structure:")
                    print(json.dumps(data['skus'][0], indent=2))
                
                # Filter for compute instances in us-central1
                new_skus = []
                for sku in data.get('skus', []):
                    category = sku.get('category', {})
                    resource_family = category.get('resourceFamily', '')
                    usage_type = category.get('usageType', '')
                    regions = sku.get('serviceRegions', [])
                    
                    # Debug: Print categories when found
                    if 'us-central1' in regions and resource_family == 'Compute':
                        print(f"\nFound compute SKU:")
                        print(f"Description: {sku.get('description', '')}")
                        print(f"Resource Family: {resource_family}")
                        print(f"Usage Type: {usage_type}")
                        print(f"Regions: {regions}")
                        new_skus.append(sku)
                
                if new_skus:
                    skus.extend(new_skus)
                    print(f"Found {len(new_skus)} compute instances in us-central1")
                
                if 'nextPageToken' not in data:
                    break
                    
                params['pageToken'] = data['nextPageToken']
                page_count += 1
                
            except requests.exceptions.RequestException as e:
                print(f"Error fetching SKUs: {e}")
                raise
            
        print(f"\nTotal compute instances found: {len(skus)}")
        return skus

def format_for_morpheus(skus: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Format GCP pricing data into Morpheus price set format"""
    print("\nFormatting pricing data for Morpheus...")
    
    # Group compute instances by machine type
    machine_types = {}
    
    for sku in skus:
        if not sku.get('pricingInfo'):
            continue
            
        category = sku.get('category', {})
        description = sku.get('description', '')
        machine_type = category.get('resourceGroup', '')
                
        pricing_info = sku['pricingInfo'][0]
        price_expression = pricing_info.get('pricingExpression', {})
        
        # Get base price
        price = 0.0
        if price_expression.get('tieredRates'):
            rate = price_expression['tieredRates'][0]
            price = float(rate['unitPrice'].get('units', 0))
            nanos = float(rate['unitPrice'].get('nanos', 0)) / 1e9
            price += nanos
            
        # Create price set entry
        price_set = {
            "priceSet": {
                "name": f"Google - Compute Engine - {machine_type} - us-central1",
                "code": f"google.compute.{machine_type}.us-central1",
                "active": True,
                "priceUnit": "hour",
                "type": "compute",
                "regionCode": "us-central1",
                "systemCreated": True,
                "prices": [{
                    "name": description,
                    "code": f"google.{sku['skuId']}.us-central1",
                    "active": True,
                    "priceType": "compute",
                    "priceUnit": "hour",
                    "price": price,
                    "customPrice": 0,
                    "markup": 0,
                    "markupPercent": 0,
                    "cost": price,
                    "currency": "USD",
                    "incurCharges": "running",
                    "platform": "linux",
                    "software": None
                }]
            },
            "success": True
        }
        
        if machine_type not in machine_types:
            machine_types[machine_type] = price_set
        else:
            machine_types[machine_type]["priceSet"]["prices"].extend(price_set["priceSet"]["prices"])
    
    result = list(machine_types.values())
    print(f"Formatting complete. Created {len(result)} price sets")
    return result

def main():
    try:
        api_key = "AIzaSyCpiJrtLNwPlq2n8EwOOh1zUUX9vncGIuE"
        client = GCPPricingClient(api_key)
        
        skus = client.get_compute_skus(max_pages=10)
        price_sets = format_for_morpheus(skus)
        
        output_file = 'gcp_compute_pricing.json'
        with open(output_file, 'w') as f:
            json.dump(price_sets, f, indent=2)
            
        print(f"\nSuccess! Pricing data saved to {output_file}")
        print(f"Total price sets created: {len(price_sets)}")
        
    except Exception as e:
        print(f"\nError: {str(e)}")
        raise

if __name__ == "__main__":
    main()