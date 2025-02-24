import requests
import json
import logging
from typing import List, Dict, Any
import time


logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class MorpheusClient:
    def __init__(self, morpheus_url, access_token, max_retries=3, retry_delay=1):
        self.base_url = morpheus_url.rstrip('/')
        self.headers = {
            'Authorization': f'Bearer {access_token}',
            'Content-Type': 'application/json'
        }
        self.max_retries = max_retries
        self.retry_delay = retry_delay
        
    def _make_request(self, method, url, **kwargs):
        """Make HTTP request with retry logic"""
        retries = 0
        while retries < self.max_retries:
            try:
                response = requests.request(method, url, **kwargs)
                response.raise_for_status()
                return response
            except requests.exceptions.RequestException as e:
                retries += 1
                if retries == self.max_retries:
                    raise
                logger.warning(f"Request failed, retrying in {self.retry_delay} seconds... ({retries}/{self.max_retries})")
                time.sleep(self.retry_delay)
        
    def create_or_update_price(self, price_data):
        """Create or update a price in Morpheus"""
        code = price_data['price']['code']
        logger.info(f"Searching for existing price with code: {code}")
        search_url = f"{self.base_url}/api/prices?code={code}"
        
        try:
            search_response = self._make_request('GET', search_url, headers=self.headers)
            search_data = search_response.json()
            
            price_id = None
            if search_data.get('prices') and len(search_data['prices']) > 0:
                price_id = search_data['prices'][0]['id']
                logger.info(f"Found existing price with ID: {price_id}, updating...")
                url = f"{self.base_url}/api/prices/{price_id}"
                response = self._make_request('PUT', url, headers=self.headers, json=price_data)
            else:
                logger.info("No existing price found, creating new...")
                url = f"{self.base_url}/api/prices"
                response = self._make_request('POST', url, headers=self.headers, json=price_data)
                resp_data = response.json()
                if resp_data.get('success') and resp_data.get('id'):
                    price_id = resp_data['id']
                
            result = response.json()
            result['price_id'] = price_id
            return result
            
        except requests.exceptions.RequestException as e:
            logger.error(f"Error in create_or_update_price: {str(e)}")
            raise
        
    def create_price_set(self, price_set_data):
        """Create a new price set in Morpheus"""
        url = f"{self.base_url}/api/price-sets"
        try:
            response = self._make_request('POST', url, headers=self.headers, json=price_set_data)
            return response.json()
        except requests.exceptions.RequestException as e:
            logger.error(f"Error creating price set: {str(e)}")
            raise

class GCPPricingClient:
    def __init__(self, api_key, region="asia-southeast1"):
        self.api_key = api_key
        self.base_url = "https://cloudbilling.googleapis.com/v1"
        self.region = region
        
    def get_all_skus(self, max_pages=10):
        """Get all SKUs for specified region"""
        logger.info(f"Fetching all SKUs for {self.region}...")
        url = f"{self.base_url}/services/6F81-5844-456A/skus"
        params = {
            'key': self.api_key,
            'pageSize': 100
        }
        
        skus = []
        resource_families = set()
        resource_groups = set()
        usage_types = set()
        sku_types = {}
        page_count = 1
        
        while page_count <= max_pages:
            try:
                logger.info(f"Fetching page {page_count}...")
                response = requests.get(url, params=params)
                response.raise_for_status()
                data = response.json()
                
                new_skus = []
                for sku in data.get('skus', []):
                    if self._is_valid_sku(sku):
                        new_skus.append(sku)
                        
                        category = sku.get('category', {})
                        family = category.get('resourceFamily', 'Unknown')
                        group = category.get('resourceGroup', 'Unknown')
                        usage = category.get('usageType', 'Unknown')
                        
                        resource_families.add(family)
                        resource_groups.add(group)
                        usage_types.add(usage)
                        
                        key = f"{family}/{group}/{usage}"
                        sku_types[key] = sku_types.get(key, 0) + 1
                
                if new_skus:
                    skus.extend(new_skus)
                    logger.info(f"Found {len(new_skus)} SKUs on page {page_count}")
                
                if 'nextPageToken' not in data:
                    break
                    
                params['pageToken'] = data['nextPageToken']
                page_count += 1
                
            except requests.exceptions.RequestException as e:
                logger.error(f"Error fetching SKUs: {e}")
                raise
        
        self._log_sku_analysis(skus, resource_families, resource_groups, usage_types, sku_types)
        return skus
    
    def _is_valid_sku(self, sku):
        """Check if SKU is valid for the specified region"""
        return self.region in sku.get('serviceRegions', [])
    
    def _log_sku_analysis(self, skus, resource_families, resource_groups, usage_types, sku_types):
        """Log detailed SKU analysis"""
        logger.info(f"\nTotal SKUs found: {len(skus)}")
        
        logger.info(f"\nResource Families ({len(resource_families)}):")
        for family in sorted(resource_families):
            logger.info(f"  - {family}")
            
        logger.info(f"\nResource Groups ({len(resource_groups)}):")
        for group in sorted(resource_groups):
            logger.info(f"  - {group}")
            
        logger.info(f"\nUsage Types ({len(usage_types)}):")
        for usage in sorted(usage_types):
            logger.info(f"  - {usage}")
            
        logger.info("\nDetailed SKU counts by category:")
        for category, count in sorted(sku_types.items()):
            logger.info(f"  {category}: {count}")

def _get_price_type(resource_group, resource_family=None):
    """Enhanced type mapping for GCP to Morpheus"""
    compute_types = {
        'CPU': 'cores',
        'RAM': 'memory',
        'GPU': 'gpu',
        'TPU': 'compute',
        'N1Standard': 'compute'
    }
    
    storage_types = {
        'PDStandard': 'storage',
        'SSD': 'storage',
        'Storage': 'storage'
    }
    

    network_types = {
        'InterregionEgress': 'compute',
        'VPNInternetIngress': 'compute',
        'VPNInterregionEgress': 'compute',
        'VPNInterregionIngress': 'compute'
    }
    
    if resource_family == "Compute":
        return compute_types.get(resource_group, 'compute')
    elif resource_family == "Storage":
        return storage_types.get(resource_group, 'storage')
    elif resource_family == "Network":
        return network_types.get(resource_group, 'compute')
        
    return 'compute'  

def _get_volume_type(resource_group):
    """Map GCP storage types to Morpheus volume types"""
    volume_mapping = {
        'PDStandard': 1,  
        'SSD': 2,
        'Storage': 1
    }
    return volume_mapping.get(resource_group, 1)  

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
    
    resource_family = category.get('resourceFamily', '')
    resource_group = category.get('resourceGroup', '')
    
    price_data = {
        "price": {
            "name": f"{price_prefix} - {sku.get('description', '')}",
            "code": f"{price_prefix.lower()}.google.{sku['skuId']}.{region}",
            "active": True,
            "priceType": _get_price_type(resource_group, resource_family),
            "priceUnit": "hour",
            "price": base_price,
            "cost": base_price,
            "currency": "USD",
            "incurCharges": "running"
        }
    }
    

    if resource_family == 'Storage':
        price_data["price"]["volumeType"] = _get_volume_type(resource_group)
    
    return price_data

def create_price_set_data(category_key, price_ids, region, price_prefix):
    """Create price set data structure for Morpheus API"""

    family = category_key.split('/')[0] if '/' in category_key else category_key
    

    price_set_type = 'compute'  # Default type
    if family == 'Storage':
        price_set_type = 'storage'
    
    return {
        "priceSet": {
            "name": f"{price_prefix} - Google - {category_key} - {region}",
            "code": f"{price_prefix.lower()}.google.{category_key.lower()}.{region}",
            "active": True,
            "priceUnit": "hour",
            "type": price_set_type,
            "regionCode": region,
            "prices": price_ids
        }
    }

def process_pricing_data(skus, morpheus_client, region, price_prefix):
    """Process SKUs and create prices and price sets in Morpheus"""
    logger.info("Starting to process pricing data...")
    
 
    category_groups = {}
    for sku in skus:
        category = sku.get('category', {})
        category_key = f"{category.get('resourceFamily', 'Unknown')}/{category.get('resourceGroup', 'Unknown')}"
        
        if category_key not in category_groups:
            category_groups[category_key] = []
        category_groups[category_key].append(sku)
    
    for category_key, category_skus in category_groups.items():
        try:
            
            price_ids = []
            for sku in category_skus:
                price_data = create_price_data(sku, region, price_prefix)
                if price_data:
                    try:
                        price_response = morpheus_client.create_or_update_price(price_data)
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
                price_set_data = create_price_set_data(category_key, price_ids, region, price_prefix)
                morpheus_client.create_price_set(price_set_data)
                logger.info(f"Successfully created price set for {category_key}")
                
        except Exception as e:
            logger.error(f"Error processing category {category_key}: {str(e)}")

def main():
    try:
        # Configuration
        gcp_api_key = "xxxxxxxxxxxxxxxxxxxxxxxxxx"
        morpheus_url = "https://xxxx.morphe.com"
        morpheus_token = "xxxxxxxxxxxxxxxxxx"
        region = "asia-southeast1"
        price_prefix = "Aswath" # Configurable prefix for prices and price sets
        
        # Initialize clients
        gcp_client = GCPPricingClient(gcp_api_key, region)
        morpheus_client = MorpheusClient(morpheus_url, morpheus_token)
        
        # Get GCP pricing data
        skus = gcp_client.get_all_skus()
        
        # Process and upload to Morpheus
        process_pricing_data(skus, morpheus_client, region, price_prefix)
        
        logger.info("Pricing sync completed successfully")
        
    except Exception as e:
        logger.error(f"Error in main execution: {e}")
        raise

if __name__ == "__main__":
    main()