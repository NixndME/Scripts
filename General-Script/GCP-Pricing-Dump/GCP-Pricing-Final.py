import requests
import json
import logging
from typing import List, Dict, Any

# logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class MorpheusClient:
    def __init__(self, morpheus_url, access_token):
        self.base_url = morpheus_url.rstrip('/')
        self.headers = {
            'Authorization': f'Bearer {access_token}',
            'Content-Type': 'application/json'
        }
        
    def create_or_update_price(self, price_data):
        """Create or update a price in Morpheus"""

        code = price_data['price']['code']
        logger.info(f"Searching for existing price with code: {code}")
        search_url = f"{self.base_url}/api/prices?code={code}"
        search_response = requests.get(search_url, headers=self.headers)
        search_response.raise_for_status()
        search_data = search_response.json()
        
        price_id = None
        if search_data.get('prices') and len(search_data['prices']) > 0:

            price_id = search_data['prices'][0]['id']
            logger.info(f"Found existing price with ID: {price_id}, updating...")
            url = f"{self.base_url}/api/prices/{price_id}"
            response = requests.put(url, headers=self.headers, json=price_data)
            price_id = price_id  # Keep the existing ID
        else:
            logger.info("No existing price found, creating new...")
            url = f"{self.base_url}/api/prices"
            response = requests.post(url, headers=self.headers, json=price_data)
            resp_data = response.json()
            if resp_data.get('success') and resp_data.get('id'):
                price_id = resp_data['id']
            
        response.raise_for_status()
        result = response.json()
        result['price_id'] = price_id  # Add the price ID to the response
        return result
        
    def create_price_set(self, price_set_data):
        """Create a new price set in Morpheus"""
        url = f"{self.base_url}/api/price-sets"
        response = requests.post(url, headers=self.headers, json=price_set_data)
        response.raise_for_status()
        return response.json()

class GCPPricingClient:
    def __init__(self, api_key, region="asia-southeast1"):
        self.api_key = api_key
        self.base_url = "https://cloudbilling.googleapis.com/v1"
        self.region = region
        
    def get_compute_skus(self, max_pages=10):
        """Get all compute-related SKUs for specified region"""
        logger.info(f"Fetching Compute Engine SKUs for {self.region}...")
        url = f"{self.base_url}/services/6F81-5844-456A/skus"
        params = {
            'key': self.api_key,
            'pageSize': 100
        }
        
        skus = []
        page_count = 1
        
        while page_count <= max_pages:
            try:
                logger.info(f"Fetching page {page_count}...")
                response = requests.get(url, params=params)
                response.raise_for_status()
                data = response.json()
                
                new_skus = []
                for sku in data.get('skus', []):
                    if self._is_valid_compute_sku(sku):
                        new_skus.append(sku)
                
                if new_skus:
                    skus.extend(new_skus)
                    logger.info(f"Found {len(new_skus)} relevant SKUs on page {page_count}")
                
                if 'nextPageToken' not in data:
                    break
                    
                params['pageToken'] = data['nextPageToken']
                page_count += 1
                
            except requests.exceptions.RequestException as e:
                logger.error(f"Error fetching SKUs: {e}")
                raise
                
        logger.info(f"Total SKUs found: {len(skus)}")
        return skus
        
    def _is_valid_compute_sku(self, sku):
        """Check if SKU is relevant for compute pricing"""
        if self.region not in sku.get('serviceRegions', []):
            return False
            
        category = sku.get('category', {})
        resource_family = category.get('resourceFamily', '')
        resource_group = category.get('resourceGroup', '')
        
        return (resource_family == 'Compute' and 
                resource_group in ['CPU', 'RAM', 'GPU', 'LocalSSD', 'N1Standard', 'N2Standard'])

def create_price_data(sku, region, price_prefix):
    """Create price data structure for Morpheus API"""
    category = sku.get('category', {})
    pricing_info = sku.get('pricingInfo', [{}])[0]
    price_expression = pricing_info.get('pricingExpression', {})
    
    base_price = 0.0
    if price_expression.get('tieredRates'):
        rate = price_expression['tieredRates'][0]
        units = float(rate['unitPrice'].get('units', 0))
        nanos = float(rate['unitPrice'].get('nanos', 0)) / 1e9
        base_price = units + nanos
    
    resource_group = category.get('resourceGroup', '')
    price_type = _get_price_type(resource_group)
    price_unit = _get_price_unit(price_expression.get('usageUnit', ''))
    
    return {
        "price": {
            "name": f"{price_prefix} - {sku.get('description', '')}",
            "code": f"{price_prefix.lower()}.google.{sku['skuId']}.{region}",
            "active": True,
            "priceType": price_type,
            "priceUnit": price_unit,
            "price": base_price,
            "cost": base_price,
            "currency": "USD",
            "incurCharges": "running"
        }
    }

def create_price_set_data(instance_type, price_ids, region, price_prefix):
    """Create price set data structure for Morpheus API"""
    return {
        "priceSet": {
            "name": f"{price_prefix} - Google - Compute Engine - {instance_type} - {region}",
            "code": f"{price_prefix.lower()}.google.compute.{instance_type}.{region}",
            "active": True,
            "priceUnit": "hour",
            "type": "compute",
            "regionCode": region,
            "prices": price_ids
        }
    }

def _get_price_type(resource_group):
    """Map GCP resource group to Morpheus price type"""
    type_mapping = {
        'CPU': 'cores',
        'RAM': 'cores',  
        'GPU': 'cores',  
        'LocalSSD': 'storage'
    }
    return type_mapping.get(resource_group, 'compute')

def _get_price_unit(usage_unit):
    """Map GCP usage unit to Morpheus price unit"""
    return 'hour'

def process_pricing_data(skus, morpheus_client, region, price_prefix):
    """Process SKUs and create prices and price sets in Morpheus"""
    logger.info("Starting to process pricing data...")
    

    instance_groups = {}
    for sku in skus:
        instance_type = _get_instance_type(sku)
        if instance_type:
            if instance_type not in instance_groups:
                instance_groups[instance_type] = []
            instance_groups[instance_type].append(sku)
    
    for instance_type, instance_skus in instance_groups.items():
        try:
            price_ids = []
            for sku in instance_skus:
                price_data = create_price_data(sku, region, price_prefix)
                if price_data:
                    logger.info(f"Creating price with data: {json.dumps(price_data, indent=2)}")
                    try:
                        price_response = morpheus_client.create_or_update_price(price_data)
                        logger.info(f"Price response: {json.dumps(price_response, indent=2)}")
                        if price_response.get('success'):
                            price_id = price_response.get('price_id')
                            if price_id:
                                price_ids.append(price_id)
                                logger.info(f"Successfully processed price with ID: {price_id}")
                            else:
                                logger.error("No price ID returned in the response")
                        else:
                            logger.error(f"Failed to process price: {price_response}")
                    except Exception as e:
                        logger.error(f"Error processing price: {str(e)}")
                    
            if price_ids:
                price_set_data = create_price_set_data(instance_type, price_ids, region, price_prefix)
                morpheus_client.create_price_set(price_set_data)
                logger.info(f"Successfully created price set for {instance_type}")
                
        except Exception as e:
            logger.error(f"Error processing instance type {instance_type}: {str(e)}")

def _get_instance_type(sku):
    """Extract instance type from SKU"""
    description = sku.get('description', '').lower()
    category = sku.get('category', {})
    resource_group = category.get('resourceGroup', '')
    
    if 'instance' in description:
        parts = description.split()
        for part in parts:
            if part.startswith('n1-') or part.startswith('n2-') or part.startswith('e2-'):
                return part
    return resource_group

def main():
    try:
        # Configuration
        gcp_api_key = "xxxxxxxxxxxxxxxxxxxxxxx"
        morpheus_url = "https://xxxxx.morpheus.com"
        morpheus_token = "xxxxxxxxxxxxxxxxxxxx"
        region = "asia-southeast1"
        price_prefix = "Aswath" # Configurable prefix for prices and price sets
        
        
        gcp_client = GCPPricingClient(gcp_api_key, region)
        morpheus_client = MorpheusClient(morpheus_url, morpheus_token)
        
        
        skus = gcp_client.get_compute_skus()
        
        
        process_pricing_data(skus, morpheus_client, region, price_prefix)
        
        logger.info("Pricing sync completed successfully")
        
    except Exception as e:
        logger.error(f"Error in main execution: {e}")
        raise

if __name__ == "__main__":
    main()