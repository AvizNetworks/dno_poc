# ASN Cloud FastAPI AWS Service

This FastAPI project provides endpoints to interact with AWS resources:
- List all available regions
- List all VPCs in a region
- List all EC2 instances in a region
- Create and deploy new EC2 instances in a specific region/VPC

## Setup
1. Ensure your AWS credentials are configured (via environment variables or ~/.aws/credentials).
2. Install dependencies (already installed):
   - fastapi
   - uvicorn
   - boto3

## Running the API
```
/home/ilan/work/asn_cloud/.venv/bin/python -m uvicorn main:app --reload
```

## Endpoints
- `/regions` - List AWS regions
- `/vpcs?region=...` - List VPCs in a region (ID and Name)
- `/instances?region=...` - List EC2 instances in a region (ID and Name)
- `/subnets?region=...&vpc_id=...` - List subnets in a VPC (ID, Name, CIDR block, available IPs)
- `/instances_in_subnet?region=...&subnet_id=...` - List EC2 instances in a subnet (ID, Name, private/public IP)
- `/deploy` (POST) - Create and deploy EC2 instance
- `/instance_details?region=...&instance_id=...` - Get all details about a specific EC2 instance
- `/enis?region=...&vpc_id=...` - List ENIs in a VPC (ID, Subnet, IPs, status, attached instance)

## Notes
- You must have appropriate AWS permissions for these actions.
- See `main.py` for implementation details.
