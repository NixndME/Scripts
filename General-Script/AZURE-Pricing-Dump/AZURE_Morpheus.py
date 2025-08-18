#!/usr/bin/env python3

import requests
import json
import logging
import time
import sys
from datetime import datetime
from typing import List, Dict, Any, Optional
import urllib3
urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

MORPHEUS_URL = "https://your-morpheus-instance.com"
MORPHEUS_TOKEN = "your-morpheus-bearer-token"
PRICE_PREFIX = "aswath"
SKIP_SSL_VERIFY = True  # Set to False for production

AZURE_CURRENCY = "USD"
AZURE_REGIONS = [
    "eastus",
    "westus2", 
    "westeurope",
    "southeastasia",
    "australiaeast"
]

AZURE_SERVICES = [
    "Virtual Machines",
    "Storage", 
    "Bandwidth",
    "Azure SQL Database",
    "Azure Database for MySQL",
    "Azure Database for PostgreSQL"
]

MAX_PAGES_PER_SERVICE = 30
REQUEST_DELAY = 0.2
MAX_RETRIES = 3

logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(f'azure_morpheus_sync_{datetime.now().strftime("%Y%m%d")}.log')
    ]
)
logger = logging.getLogger(__name__)

class MorpheusClient:
    def __init__(self, url: str, token: str, verify_ssl: bool = True):
        self.base_url = url.rstrip('/')
        self.headers = {
            'Authorization': f'Bearer {token}',
            'Content-Type': 'application/json'
        }
        self.verify_ssl = verify_ssl
        self.session = requests.Session()
        self.session.headers.update(self.headers)
        self.session.verify = verify_ssl
    
    def _make_request(self, method: str, endpoint: str, **kwargs) -> requests.Response:
        url = f"{self.base_url}{endpoint}"
        
        if 'verify' not in kwargs:
            kwargs['verify'] = self.verify_ssl
        
        for attempt in range(MAX_RETRIES):
            try:
                response = self.session.request(method, url, **kwargs)
                response.raise_for_status()
                return response
            except requests.exceptions.RequestException as e:
                if attempt == MAX_RETRIES - 1:
                    logger.error(f"Request failed after {MAX_RETRIES} attempts: {e}")
                    raise
                logger.warning(f"Request failed (attempt {attempt + 1}/{MAX_RETRIES}), retrying...")
                time.sleep(REQUEST_DELAY * (attempt + 1))
    
    def search_price_by_code(self, code: str) -> Optional[Dict]:
        try:
            response = self._make_request('GET', f'/api/prices?code={code}')
            data = response.json()
            prices = data.get('prices', [])
            return prices[0] if prices else None
        except Exception as e:
            logger.error(f"Error searching for price {code}: {e}")
            return None
    
    def create_price(self, price_data: Dict) -> Optional[int]:
        try:
            response = self._make_request('POST', '/api/prices', json=price_data)
            result = response.json()
            if result.get('success'):
                price_id = result.get('id') or result.get('price', {}).get('id')
                logger.info(f"Created price: {price_data['price']['name']} (ID: {price_id})")
                return price_id
            else:
                logger.error(f"Failed to create price: {result}")
                return None
        except Exception as e:
            logger.error(f"Error creating price: {e}")
            return None
    
    def update_price(self, price_id: int, price_data: Dict) -> bool:
        try:
            response = self._make_request('PUT', f'/api/prices/{price_id}', json=price_data)
            result = response.json()
            if result.get('success'):
                logger.info(f"Updated price: {price_data['price']['name']} (ID: {price_id})")
                return True
            else:
                logger.error(f"Failed to update price: {result}")
                return False
        except Exception as e:
            logger.error(f"Error updating price {price_id}: {e}")
            return False
    
    def create_or_update_price(self, price_data: Dict) -> Optional[int]:
        code = price_data['price']['code']
        existing_price = self.search_price_by_code(code)
        
        if existing_price:
            price_id = existing_price['id']
            success = self.update_price(price_id, price_data)
            return price_id if success else None
        else:
            return self.create_price(price_data)
    
    def create_price_set(self, price_set_data: Dict) -> bool:
        try:
            response = self._make_request('POST', '/api/price-sets', json=price_set_data)
            result = response.json()
            if result.get('success'):
                logger.info(f"Created price set: {price_set_data['priceSet']['name']}")
                return True
            else:
                logger.error(f"Failed to create price set: {result}")
                return False
        except Exception as e:
            logger.error(f"Error creating price set: {e}")
            return False

class AzurePricingClient:
    def __init__(self, currency: str = "USD"):
        self.base_url = "https://prices.azure.com/api/retail/prices"
        self.currency = currency
    
    def fetch_service_pricing(self, service_name: str, regions: List[str]) -> List[Dict]:
        logger.info(f"Fetching pricing for {service_name}...")
        all_items = []
        
        for region in regions:
            logger.info(f"  Fetching {service_name} pricing for {region}...")
            
            params = {
                'currencyCode': self.currency,
                '$filter': f"serviceName eq '{service_name}' and armRegionName eq '{region}' and priceType eq 'Consumption'"
            }
            
            items = self._fetch_paginated_data(params, MAX_PAGES_PER_SERVICE)
            all_items.extend(items)
            logger.info(f"  Found {len(items)} items for {service_name} in {region}")
            
            time.sleep(REQUEST_DELAY)
        
        return all_items
    
    def _fetch_paginated_data(self, params: Dict, max_pages: int) -> List[Dict]:
        items = []
        next_url = self.base_url
        page_count = 0
        
        while next_url and page_count < max_pages:
            try:
                if page_count == 0:
                    response = requests.get(next_url, params=params)
                else:
                    response = requests.get(next_url)
                
                response.raise_for_status()
                data = response.json()
                
                page_items = data.get('Items', [])
                items.extend(page_items)
                
                next_url = data.get('NextPageLink')
                page_count += 1
                
                if page_items:
                    time.sleep(REQUEST_DELAY)
                
            except requests.exceptions.RequestException as e:
                logger.error(f"Error fetching page {page_count + 1}: {e}")
                break
        
        return items

class PricingConverter:
    def __init__(self, prefix: str):
        self.prefix = prefix
    
    def convert_azure_to_morpheus_price(self, azure_item: Dict) -> Dict:
        service_name = azure_item.get('serviceName', '')
        meter_name = azure_item.get('meterName', '')
        product_name = azure_item.get('productName', '')
        location = azure_item.get('location', '')
        region_name = azure_item.get('armRegionName', '')
        retail_price = float(azure_item.get('retailPrice', 0))
        meter_id = azure_item.get('meterId', '')
        unit_of_measure = azure_item.get('unitOfMeasure', '1 Hour')
        
        price_type = self._get_price_type(service_name, meter_name, product_name)
        platform = self._get_platform(product_name, meter_name)
        
        if platform == 'windows' and price_type == 'compute':
            price_type = 'platform'
        
        price_unit = self._get_price_unit(unit_of_measure, price_type)
        
        price_data = {
            "price": {
                "name": f"{self.prefix} - {product_name} - {meter_name} - {location}",
                "code": f"{self.prefix.lower()}.azure.{meter_id}.{region_name}",
                "active": True,
                "priceType": price_type,
                "priceUnit": price_unit,
                "additionalPriceUnit": "GB" if price_type == "storage" else None,
                "price": retail_price,
                "customPrice": 0,
                "markupType": None,
                "markup": 0,
                "markupPercent": 0,
                "cost": retail_price,
                "currency": "USD",
                "incurCharges": "always" if price_type == "storage" else "running",
                "platform": platform,
                "software": None,
                "volumeType": self._get_volume_type(meter_name, product_name) if price_type == "storage" else None,
                "datastore": None,
                "crossCloudApply": None,
                "account": None
            }
        }
        
        return price_data
    
    def _get_price_type(self, service_name: str, meter_name: str, product_name: str) -> str:
        service_lower = service_name.lower()
        meter_lower = meter_name.lower()
        product_lower = product_name.lower()
        
        if any(keyword in product_lower for keyword in ['windows']):
            return 'platform'
        elif any(keyword in service_lower for keyword in ['storage', 'disk', 'blob', 'file']):
            return 'storage'
        elif service_name == "Virtual Machines":
            if any(keyword in meter_lower for keyword in ['ram', 'memory']):
                return 'memory'
            elif any(keyword in meter_lower for keyword in ['core', 'cpu', 'vcpu']):
                return 'cores'
            else:
                return 'compute'
        elif any(keyword in service_lower for keyword in ['sql', 'database', 'mysql', 'postgresql']):
            return 'compute'
        else:
            return 'compute'
    
    def _get_platform(self, product_name: str, meter_name: str) -> Optional[str]:
        combined = f"{product_name} {meter_name}".lower()
        
        if 'windows' in combined:
            return 'windows'
        elif 'linux' in combined:
            return 'linux'
        
        return None
    
    def _get_price_unit(self, unit_of_measure: str, price_type: str) -> str:
        unit_lower = unit_of_measure.lower()
        
        if price_type == "storage":
            if 'month' in unit_lower:
                return 'month'
            return 'hour'
        
        return 'hour'
    
    def _get_volume_type(self, meter_name: str, product_name: str) -> Optional[Dict]:
        combined = f"{meter_name} {product_name}".lower()
        
        if any(keyword in combined for keyword in ['premium', 'ssd']):
            return {
                "id": None,
                "code": f"{self.prefix.lower()}-premium-ssd",
                "name": "Premium SSD"
            }
        elif any(keyword in combined for keyword in ['standard', 'hdd']):
            return {
                "id": None,
                "code": f"{self.prefix.lower()}-standard-hdd", 
                "name": "Standard HDD"
            }
        else:
            return {
                "id": None,
                "code": f"{self.prefix.lower()}-standard",
                "name": "Standard"
            }
    
    def group_prices_for_price_sets(self, morpheus_prices: List[Dict]) -> Dict[str, List[int]]:
        groups = {}
        
        for price_data in morpheus_prices:
            price = price_data['price']
            name = price['name']
            price_id = price_data.get('price_id')
            
            if not price_id:
                continue
            
            name_parts = name.split(' - ')
            if len(name_parts) >= 4:
                service_part = name_parts[1]
                region_part = name_parts[-1]
                group_key = f"{service_part}_{region_part}"
                
                if group_key not in groups:
                    groups[group_key] = []
                
                groups[group_key].append(price_id)
        
        return groups
    
    def create_price_set(self, group_key: str, price_ids: List[int]) -> Dict:
        parts = group_key.split('_', 1)
        service_name = parts[0] if parts else "Unknown"
        location = parts[1] if len(parts) > 1 else "Unknown"
        
        service_lower = service_name.lower()
        if any(keyword in service_lower for keyword in ['storage', 'disk', 'blob']):
            price_set_type = "storage"
        elif any(keyword in service_lower for keyword in ['virtual', 'compute']):
            price_set_type = "compute_plus_storage"
        else:
            price_set_type = "compute"
        
        return {
            "priceSet": {
                "name": f"{self.prefix} - Azure - {service_name} - {location}",
                "code": f"{self.prefix.lower()}.azure.{service_name.lower().replace(' ', '')}.{location.lower().replace(' ', '')}",
                "active": True,
                "priceUnit": "hour",
                "type": price_set_type,
                "regionCode": location.lower().replace(' ', ''),
                "systemCreated": True,
                "zone": None,
                "zonePool": None,
                "account": None,
                "prices": price_ids
            }
        }

def sync_azure_pricing():
    start_time = datetime.now()
    logger.info(f"Starting Azure pricing sync at {start_time}")
    logger.info(f"Configuration: Prefix={PRICE_PREFIX}, Regions={AZURE_REGIONS}, Services={AZURE_SERVICES}")
    if SKIP_SSL_VERIFY:
        logger.warning("SSL certificate verification is DISABLED")
    
    try:
        azure_client = AzurePricingClient(AZURE_CURRENCY)
        morpheus_client = MorpheusClient(MORPHEUS_URL, MORPHEUS_TOKEN, SKIP_SSL_VERIFY)
        converter = PricingConverter(PRICE_PREFIX)
        
        logger.info("Fetching Azure pricing data...")
        all_azure_items = []
        
        for service in AZURE_SERVICES:
            service_items = azure_client.fetch_service_pricing(service, AZURE_REGIONS)
            all_azure_items.extend(service_items)
            logger.info(f"Total items for {service}: {len(service_items)}")
        
        logger.info(f"Total Azure pricing items fetched: {len(all_azure_items)}")
        
        if not all_azure_items:
            logger.warning("No pricing data fetched from Azure. Exiting.")
            return False
        
        logger.info("Converting and uploading prices to Morpheus...")
        successful_prices = []
        failed_count = 0
        
        for i, azure_item in enumerate(all_azure_items):
            try:
                morpheus_price = converter.convert_azure_to_morpheus_price(azure_item)
                price_id = morpheus_client.create_or_update_price(morpheus_price)
                
                if price_id:
                    morpheus_price['price_id'] = price_id
                    successful_prices.append(morpheus_price)
                else:
                    failed_count += 1
                
                if (i + 1) % 100 == 0:
                    logger.info(f"Processed {i + 1}/{len(all_azure_items)} items...")
                    
            except Exception as e:
                logger.error(f"Error processing item {i}: {e}")
                failed_count += 1
        
        logger.info(f"Price upload complete. Success: {len(successful_prices)}, Failed: {failed_count}")
        
        if successful_prices:
            logger.info("Creating price sets...")
            price_groups = converter.group_prices_for_price_sets(successful_prices)
            
            price_set_success = 0
            price_set_failed = 0
            
            for group_key, price_ids in price_groups.items():
                if len(price_ids) > 0:
                    try:
                        price_set_data = converter.create_price_set(group_key, price_ids)
                        success = morpheus_client.create_price_set(price_set_data)
                        if success:
                            price_set_success += 1
                        else:
                            price_set_failed += 1
                    except Exception as e:
                        logger.error(f"Error creating price set for {group_key}: {e}")
                        price_set_failed += 1
            
            logger.info(f"Price set creation complete. Success: {price_set_success}, Failed: {price_set_failed}")
        
        end_time = datetime.now()
        duration = end_time - start_time
        
        logger.info("=" * 60)
        logger.info("SYNC SUMMARY")
        logger.info("=" * 60)
        logger.info(f"Start time: {start_time}")
        logger.info(f"End time: {end_time}")
        logger.info(f"Duration: {duration}")
        logger.info(f"Azure items fetched: {len(all_azure_items)}")
        logger.info(f"Prices created/updated: {len(successful_prices)}")
        logger.info(f"Price creation failures: {failed_count}")
        if 'price_set_success' in locals():
            logger.info(f"Price sets created: {price_set_success}")
            logger.info(f"Price set failures: {price_set_failed}")
        logger.info("=" * 60)
        
        return len(successful_prices) > 0
        
    except Exception as e:
        logger.error(f"Critical error during sync: {e}")
        return False

def test_configuration():
    logger.info("Testing configuration...")
    if SKIP_SSL_VERIFY:
        logger.warning("SSL certificate verification is DISABLED")
    
    try:
        morpheus_client = MorpheusClient(MORPHEUS_URL, MORPHEUS_TOKEN, SKIP_SSL_VERIFY)
        response = morpheus_client._make_request('GET', '/api/prices?max=1')
        logger.info("✓ Morpheus API connectivity successful")
    except Exception as e:
        logger.error(f"✗ Morpheus API connectivity failed: {e}")
        return False
    
    try:
        azure_client = AzurePricingClient(AZURE_CURRENCY)
        test_items = azure_client._fetch_paginated_data({
            'currencyCode': AZURE_CURRENCY,
            '$filter': "serviceName eq 'Virtual Machines'",
            'max': 1
        }, 1)
        logger.info("✓ Azure Retail API connectivity successful")
    except Exception as e:
        logger.error(f"✗ Azure Retail API connectivity failed: {e}")
        return False
    
    logger.info("✓ Configuration test passed")
    return True

def test_azure_only():
    logger.info("Testing Azure API and downloading sample pricing data...")
    
    try:
        azure_client = AzurePricingClient(AZURE_CURRENCY)
        converter = PricingConverter(PRICE_PREFIX)
        
        test_service = "Virtual Machines"
        test_region = AZURE_REGIONS[0] if AZURE_REGIONS else "eastus"
        
        logger.info(f"Testing with service: {test_service}, region: {test_region}")
        
        params = {
            'currencyCode': AZURE_CURRENCY,
            '$filter': f"serviceName eq '{test_service}' and armRegionName eq '{test_region}' and priceType eq 'Consumption'"
        }
        
        test_items = azure_client._fetch_paginated_data(params, 2)
        logger.info(f"✓ Azure API test successful. Found {len(test_items)} items")
        
        if test_items:
            morpheus_prices = []
            for item in test_items[:10]:
                try:
                    morpheus_price = converter.convert_azure_to_morpheus_price(item)
                    morpheus_prices.append(morpheus_price)
                except Exception as e:
                    logger.warning(f"Error converting item: {e}")
            
            azure_output_file = f'azure_raw_data_{datetime.now().strftime("%Y%m%d_%H%M%S")}.json'
            with open(azure_output_file, 'w') as f:
                json.dump(test_items, f, indent=2)
            logger.info(f"✓ Raw Azure data saved to: {azure_output_file}")
            
            morpheus_output_file = f'azure_morpheus_format_{datetime.now().strftime("%Y%m%d_%H%M%S")}.json'
            with open(morpheus_output_file, 'w') as f:
                json.dump(morpheus_prices, f, indent=2)
            logger.info(f"✓ Morpheus format data saved to: {morpheus_output_file}")
            
            logger.info("\n" + "="*50)
            logger.info("SAMPLE AZURE DATA:")
            logger.info("="*50)
            if test_items:
                sample = test_items[0]
                logger.info(f"Service: {sample.get('serviceName')}")
                logger.info(f"Product: {sample.get('productName')}")
                logger.info(f"Meter: {sample.get('meterName')}")
                logger.info(f"Location: {sample.get('location')}")
                logger.info(f"Price: ${sample.get('retailPrice')} {sample.get('unitOfMeasure')}")
            
            logger.info("\n" + "="*50)
            logger.info("SAMPLE MORPHEUS CONVERSION:")
            logger.info("="*50)
            if morpheus_prices:
                sample_morpheus = morpheus_prices[0]['price']
                logger.info(f"Name: {sample_morpheus['name']}")
                logger.info(f"Code: {sample_morpheus['code']}")
                logger.info(f"Price Type: {sample_morpheus['priceType']}")
                logger.info(f"Price: ${sample_morpheus['price']} per {sample_morpheus['priceUnit']}")
                logger.info(f"Platform: {sample_morpheus.get('platform', 'None')}")
            
            logger.info("="*50)
            logger.info(f"✓ Azure API test completed successfully!")
            logger.info(f"Files created:")
            logger.info(f"  - {azure_output_file} (raw Azure data)")
            logger.info(f"  - {morpheus_output_file} (Morpheus format)")
            
            return True
        else:
            logger.warning("No data received from Azure API")
            return False
            
    except Exception as e:
        logger.error(f"✗ Azure API test failed: {e}")
        return False

def download_all_azure_pricing():
    start_time = datetime.now()
    logger.info(f"Starting Azure pricing download at {start_time}")
    logger.info(f"Configuration: Prefix={PRICE_PREFIX}, Regions={AZURE_REGIONS}, Services={AZURE_SERVICES}")
    
    try:
        azure_client = AzurePricingClient(AZURE_CURRENCY)
        converter = PricingConverter(PRICE_PREFIX)
        
        logger.info("Fetching Azure pricing data...")
        all_azure_items = []
        
        for service in AZURE_SERVICES:
            service_items = azure_client.fetch_service_pricing(service, AZURE_REGIONS)
            all_azure_items.extend(service_items)
            logger.info(f"Total items for {service}: {len(service_items)}")
        
        logger.info(f"Total Azure pricing items fetched: {len(all_azure_items)}")
        
        if not all_azure_items:
            logger.warning("No pricing data fetched from Azure.")
            return False
        
        logger.info("Converting to Morpheus format...")
        morpheus_prices = []
        failed_conversions = 0
        
        for i, azure_item in enumerate(all_azure_items):
            try:
                morpheus_price = converter.convert_azure_to_morpheus_price(azure_item)
                morpheus_prices.append(morpheus_price)
                
                if (i + 1) % 500 == 0:
                    logger.info(f"Converted {i + 1}/{len(all_azure_items)} items...")
                    
            except Exception as e:
                logger.error(f"Error converting item {i}: {e}")
                failed_conversions += 1
        
        logger.info(f"Conversion complete. Success: {len(morpheus_prices)}, Failed: {failed_conversions}")
        
        if morpheus_prices:
            logger.info("Creating price set structures...")
            
            for i, price in enumerate(morpheus_prices):
                price['price_id'] = 1000 + i
            
            price_groups = converter.group_prices_for_price_sets(morpheus_prices)
            
            price_sets = []
            for group_key, price_ids in price_groups.items():
                if len(price_ids) > 0:
                    price_set_data = converter.create_price_set(group_key, price_ids)
                    price_sets.append(price_set_data)
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        azure_file = f'azure_raw_data_{timestamp}.json'
        with open(azure_file, 'w') as f:
            json.dump(all_azure_items, f, indent=2)
        
        prices_file = f'azure_morpheus_prices_{timestamp}.json'
        with open(prices_file, 'w') as f:
            json.dump(morpheus_prices, f, indent=2)
        
        price_sets_file = f'azure_morpheus_price_sets_{timestamp}.json'
        with open(price_sets_file, 'w') as f:
            json.dump(price_sets, f, indent=2)
        
        end_time = datetime.now()
        duration = end_time - start_time
        
        logger.info("=" * 60)
        logger.info("DOWNLOAD SUMMARY")
        logger.info("=" * 60)
        logger.info(f"Start time: {start_time}")
        logger.info(f"End time: {end_time}")
        logger.info(f"Duration: {duration}")
        logger.info(f"Azure items fetched: {len(all_azure_items)}")
        logger.info(f"Prices converted: {len(morpheus_prices)}")
        logger.info(f"Conversion failures: {failed_conversions}")
        logger.info(f"Price sets created: {len(price_sets) if 'price_sets' in locals() else 0}")
        logger.info("")
        logger.info("Files created:")
        logger.info(f"  - {azure_file} ({len(all_azure_items)} raw Azure items)")
        logger.info(f"  - {prices_file} ({len(morpheus_prices)} Morpheus prices)")
        logger.info(f"  - {price_sets_file} ({len(price_sets) if 'price_sets' in locals() else 0} price sets)")
        logger.info("=" * 60)
        
        return True
        
    except Exception as e:
        logger.error(f"Critical error during download: {e}")
        return False

if __name__ == "__main__":
    import argparse
    
    parser = argparse.ArgumentParser(description="Azure to Morpheus Pricing Sync")
    parser.add_argument('--test', action='store_true', help='Test full configuration (Morpheus + Azure)')
    parser.add_argument('--test-azure', action='store_true', help='Test Azure API only and download sample data')
    parser.add_argument('--download-only', action='store_true', help='Download all Azure pricing and save locally (no Morpheus upload)')
    
    args = parser.parse_args()
    
    if args.test:
        success = test_configuration()
        sys.exit(0 if success else 1)
    
    if args.test_azure:
        success = test_azure_only()
        sys.exit(0 if success else 1)
    
    if args.download_only:
        success = download_all_azure_pricing()
        sys.exit(0 if success else 1)
    
    try:
        success = sync_azure_pricing()
        
        if success:
            logger.info("Azure pricing sync completed successfully!")
            sys.exit(0)
        else:
            logger.error("Azure pricing sync failed!")
            sys.exit(1)
            
    except KeyboardInterrupt:
        logger.info("Sync interrupted by user")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        sys.exit(1)
