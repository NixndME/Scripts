import boto3
import json
from datetime import datetime

def get_all_ec2_pricing():
    pricing_client = boto3.client('pricing', region_name='us-east-1')
    
    def get_products(service_code, filters):
        all_products = []
        next_token = None
        
        while True:
            kwargs = {
                'ServiceCode': service_code,
                'Filters': filters
            }
            if next_token:
                kwargs['NextToken'] = next_token
                
            response = pricing_client.get_products(**kwargs)
            all_products.extend(response['PriceList'])
            
            next_token = response.get('NextToken')
            if not next_token:
                break
                
        return all_products

    def create_price_entry(name, code, price_type, price_unit, price, platform=None, volume_type=None):
        return {
            "name": name,
            "code": code,
            "active": True,
            "priceType": price_type,
            "priceUnit": price_unit,
            "additionalPriceUnit": "GB" if price_type == "storage" else None,
            "price": float(price),
            "customPrice": 0,
            "markupType": None,
            "markup": 0,
            "markupPercent": 0,
            "cost": float(price),
            "currency": "USD",
            "incurCharges": "always" if price_type == "storage" else "running",
            "platform": platform,
            "software": None,
            "volumeType": volume_type,
            "datastore": None,
            "crossCloudApply": None,
            "account": None
        }

    # Get all EC2 instance types
    instance_filters = [
        {'Type': 'TERM_MATCH', 'Field': 'location', 'Value': 'US East (N. Virginia)'},
        {'Type': 'TERM_MATCH', 'Field': 'operatingSystem', 'Value': 'Linux'},
        {'Type': 'TERM_MATCH', 'Field': 'tenancy', 'Value': 'Shared'},
        {'Type': 'TERM_MATCH', 'Field': 'capacitystatus', 'Value': 'Used'}
    ]
    
    ec2_products = get_products('AmazonEC2', instance_filters)
    price_sets = []

    for product in ec2_products:
        product_data = json.loads(product)
        attributes = product_data['product']['attributes']
        
        # Skip if not an EC2 instance
        if attributes.get('servicecode') != 'AmazonEC2':
            continue
            
        instance_type = attributes.get('instanceType')
        if not instance_type:
            continue

        prices = []
        
        # Add EBS storage prices
        ebs_volume_types = {
            'io1': {'name': 'io1', 'price': 0.125},
            'sc1': {'name': 'sc1', 'price': 0.025},
            'st1': {'name': 'st1', 'price': 0.045},
            'standard': {'name': 'standard', 'price': 0.05}
        }

        for vol_type, details in ebs_volume_types.items():
            volume_type = {
                "id": None,
                "code": f"amazon-{vol_type}",
                "name": vol_type
            }
            
            prices.append(create_price_entry(
                name=f"Amazon - EBS ({vol_type}) - US East (N. Virginia)",
                code=f"amazon.storage.{vol_type}.ec2.us-east-1.amazonaws.com",
                price_type="storage",
                price_unit="month",
                price=details['price'],
                volume_type=volume_type
            ))

        # Add compute prices for Linux and Windows
        for os_type in ['Linux', 'Windows']:
            on_demand_price = 0.0  # You'll need to extract this from product_data
            
            for term in product_data.get('terms', {}).get('OnDemand', {}).values():
                for price_dimension in term.get('priceDimensions', {}).values():
                    on_demand_price = float(price_dimension.get('pricePerUnit', {}).get('USD', 0))
                    break
                break

            prices.append(create_price_entry(
                name=f"Amazon - {instance_type} - US East (N. Virginia) - {os_type}",
                code=f"amazon.{instance_type}.ec2.us-east-1.amazonaws.com.{os_type}",
                price_type="compute" if os_type == "Linux" else "platform",
                price_unit="hour",
                price=on_demand_price,
                platform=os_type.lower()
            ))

        price_set = {
            "priceSet": {
                "id": None,
                "name": f"Amazon - {instance_type} - US East (N. Virginia)",
                "code": f"amazon.{instance_type}.ec2.us-east-1.amazonaws.com",
                "active": True,
                "priceUnit": "hour",
                "type": "compute_plus_storage",
                "regionCode": "ec2.us-east-1.amazonaws.com",
                "systemCreated": True,
                "zone": None,
                "zonePool": None,
                "account": None,
                "prices": prices
            },
            "success": True
        }
        
        price_sets.append(price_set)

    return price_sets

if __name__ == "__main__":
    pricing_data = get_all_ec2_pricing()
    
    with open('aws_all_pricing.json', 'w') as f:
        json.dump(pricing_data, f, indent=2)
    
    print(f"Pricing data for {len(pricing_data)} instance types saved to aws_all_pricing.json")