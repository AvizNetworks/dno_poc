from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import boto3
from typing import List, Optional

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://10.4.5.169:8080"], 
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

class DeployInstanceRequest(BaseModel):
    region: str
    vpc_id: str
    ami_id: str
    instance_type: str
    key_name: Optional[str] = None
    subnet_id: Optional[str] = None  # Add subnet_id for precise placement

@app.get("/regions", response_model=List[str])
def list_regions():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    regions = ec2.describe_regions()["Regions"]
    return [r["RegionName"] for r in regions]

@app.get("/vpcs", response_model=List[dict])
def list_vpcs(region: str):
    ec2 = boto3.client("ec2", region_name=region)
    vpcs = ec2.describe_vpcs()["Vpcs"]
    result = []
    for v in vpcs:
        vpc_id = v["VpcId"]
        name = None
        for tag in v.get("Tags", []):
            if tag["Key"] == "Name":
                name = tag["Value"]
                break
        result.append({"VpcId": vpc_id, "Name": name})
    return result

@app.get("/instances", response_model=List[dict])
def list_instances(region: str):
    ec2 = boto3.client("ec2", region_name=region)
    reservations = ec2.describe_instances()["Reservations"]
    result = []
    for reservation in reservations:
        for instance in reservation["Instances"]:
            instance_id = instance["InstanceId"]
            name = None
            for tag in instance.get("Tags", []):
                if tag["Key"] == "Name":
                    name = tag["Value"]
                    break
            result.append({"InstanceId": instance_id, "Name": name})
    return result

@app.get("/subnets", response_model=List[dict])
def list_subnets(region: str, vpc_id: str):
    ec2 = boto3.client("ec2", region_name=region)
    subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["Subnets"]
    result = []
    for subnet in subnets:
        subnet_id = subnet["SubnetId"]
        name = None
        for tag in subnet.get("Tags", []):
            if tag["Key"] == "Name":
                name = tag["Value"]
                break
        cidr_block = subnet.get("CidrBlock")
        available_ips = subnet.get("AvailableIpAddressCount")
        result.append({
            "SubnetId": subnet_id,
            "Name": name,
            "CidrBlock": cidr_block,
            "AvailableIpAddressCount": available_ips
        })
    return result

@app.get("/instances_in_subnet", response_model=List[dict])
def instances_in_subnet(region: str, subnet_id: str):
    ec2 = boto3.client("ec2", region_name=region)
    reservations = ec2.describe_instances(Filters=[{"Name": "subnet-id", "Values": [subnet_id]}])["Reservations"]
    result = []
    for reservation in reservations:
        for instance in reservation["Instances"]:
            instance_id = instance["InstanceId"]
            name = None
            for tag in instance.get("Tags", []):
                if tag["Key"] == "Name":
                    name = tag["Value"]
                    break
            private_ip = instance.get("PrivateIpAddress")
            public_ip = instance.get("PublicIpAddress")
            result.append({
                "InstanceId": instance_id,
                "Name": name,
                "PrivateIpAddress": private_ip,
                "PublicIpAddress": public_ip
            })
    return result

@app.post("/deploy")
def deploy_instance(req: DeployInstanceRequest):
    ec2 = boto3.client("ec2", region_name=req.region)
    subnet_id = req.subnet_id
    if not subnet_id:
        subnets = ec2.describe_subnets(Filters=[{"Name": "vpc-id", "Values": [req.vpc_id]}])["Subnets"]
        if not subnets:
            raise HTTPException(status_code=400, detail="No subnets found in the specified VPC.")
        subnet_id = subnets[0]["SubnetId"]
    try:
        response = ec2.run_instances(
            ImageId=req.ami_id,
            InstanceType=req.instance_type,
            MinCount=1,
            MaxCount=1,
            KeyName=req.key_name,
            NetworkInterfaces=[{
                "AssociatePublicIpAddress": True,
                "SubnetId": subnet_id,
                "DeviceIndex": 0,
            }],
            TagSpecifications=[{
                "ResourceType": "instance",
                "Tags": [{"Key": "Name", "Value": "AvizServiceNode"}]
            }]
        )
        instance_id = response["Instances"][0]["InstanceId"]
        return {"instance_id": instance_id}
    except Exception as e:
        raise HTTPException(status_code=400, detail=str(e))

@app.get("/instance_details", response_model=dict)
def instance_details(region: str, instance_id: str):
    ec2 = boto3.client("ec2", region_name=region)
    response = ec2.describe_instances(InstanceIds=[instance_id])
    reservations = response["Reservations"]
    if not reservations or not reservations[0]["Instances"]:
        return {}
    instance = reservations[0]["Instances"][0]
    details = {
        "InstanceId": instance.get("InstanceId"),
        "Name": next((tag["Value"] for tag in instance.get("Tags", []) if tag["Key"] == "Name"), None),
        "InstanceType": instance.get("InstanceType"),
        "State": instance.get("State", {}).get("Name"),
        "PrivateIpAddress": instance.get("PrivateIpAddress"),
        "PublicIpAddress": instance.get("PublicIpAddress"),
        "SubnetId": instance.get("SubnetId"),
        "VpcId": instance.get("VpcId"),
        "LaunchTime": str(instance.get("LaunchTime")),
        "ImageId": instance.get("ImageId"),
        "KeyName": instance.get("KeyName"),
        "SecurityGroups": instance.get("SecurityGroups"),
        "Tags": instance.get("Tags"),
        "Placement": instance.get("Placement"),
        "Monitoring": instance.get("Monitoring"),
        "IamInstanceProfile": instance.get("IamInstanceProfile"),
        "BlockDeviceMappings": instance.get("BlockDeviceMappings"),
        "Architecture": instance.get("Architecture"),
        "RootDeviceType": instance.get("RootDeviceType"),
        "VirtualizationType": instance.get("VirtualizationType"),
        "CpuOptions": instance.get("CpuOptions"),
        "CapacityReservationSpecification": instance.get("CapacityReservationSpecification"),
        "HibernationOptions": instance.get("HibernationOptions"),
        "MetadataOptions": instance.get("MetadataOptions"),
        "EnclaveOptions": instance.get("EnclaveOptions"),
        "StateTransitionReason": instance.get("StateTransitionReason"),
        "PlatformDetails": instance.get("PlatformDetails"),
        "UsageOperation": instance.get("UsageOperation"),
        "UsageOperationUpdateTime": str(instance.get("UsageOperationUpdateTime")),
        "PrivateDnsName": instance.get("PrivateDnsName"),
        "PublicDnsName": instance.get("PublicDnsName"),
        "ProductCodes": instance.get("ProductCodes"),
        "EbsOptimized": instance.get("EbsOptimized"),
        "SriovNetSupport": instance.get("SriovNetSupport"),
        "ElasticGpuAssociations": instance.get("ElasticGpuAssociations"),
        "ElasticInferenceAcceleratorAssociations": instance.get("ElasticInferenceAcceleratorAssociations"),
        "NetworkInterfaces": instance.get("NetworkInterfaces"),
        "OutpostArn": instance.get("OutpostArn"),
        "PlacementGroup": instance.get("PlacementGroup"),
        "Platform": instance.get("Platform"),
        "BootMode": instance.get("BootMode"),
        "CapacityReservationId": instance.get("CapacityReservationId"),
        "CapacityReservationSpecification": instance.get("CapacityReservationSpecification"),
        "ClientToken": instance.get("ClientToken"),
        "CpuOptions": instance.get("CpuOptions"),
        "EbsOptimized": instance.get("EbsOptimized"),
        "ElasticGpuAssociations": instance.get("ElasticGpuAssociations"),
        "ElasticInferenceAcceleratorAssociations": instance.get("ElasticInferenceAcceleratorAssociations"),
        "HibernationOptions": instance.get("HibernationOptions"),
        "Hypervisor": instance.get("Hypervisor"),
        "IamInstanceProfile": instance.get("IamInstanceProfile"),
        "InstanceLifecycle": instance.get("InstanceLifecycle"),
        "LicenseSpecifications": instance.get("LicenseSpecifications"),
        "MetadataOptions": instance.get("MetadataOptions"),
        "NetworkInterfaces": instance.get("NetworkInterfaces"),
        "OutpostArn": instance.get("OutpostArn"),
        "Placement": instance.get("Placement"),
        "Platform": instance.get("Platform"),
        "PrivateDnsName": instance.get("PrivateDnsName"),
        "ProductCodes": instance.get("ProductCodes"),
        "PublicDnsName": instance.get("PublicDnsName"),
        "RootDeviceName": instance.get("RootDeviceName"),
        "RootDeviceType": instance.get("RootDeviceType"),
        "SecurityGroups": instance.get("SecurityGroups"),
        "SourceDestCheck": instance.get("SourceDestCheck"),
        "SpotInstanceRequestId": instance.get("SpotInstanceRequestId"),
        "SriovNetSupport": instance.get("SriovNetSupport"),
        "State": instance.get("State"),
        "StateReason": instance.get("StateReason"),
        "StateTransitionReason": instance.get("StateTransitionReason"),
        "SubnetId": instance.get("SubnetId"),
        "Tags": instance.get("Tags"),
        "VirtualizationType": instance.get("VirtualizationType"),
        "VpcId": instance.get("VpcId"),
    }
    return details

@app.get("/enis", response_model=List[dict])
def list_enis(region: str, vpc_id: str):
    ec2 = boto3.client("ec2", region_name=region)
    enis = ec2.describe_network_interfaces(Filters=[{"Name": "vpc-id", "Values": [vpc_id]}])["NetworkInterfaces"]
    result = []
    for eni in enis:
        eni_id = eni["NetworkInterfaceId"]
        subnet_id = eni.get("SubnetId")
        private_ip = eni.get("PrivateIpAddress")
        public_ip = None
        if eni.get("Association"):
            public_ip = eni["Association"].get("PublicIp")
        description = eni.get("Description")
        status = eni.get("Status")
        attachment = eni.get("Attachment", {})
        instance_id = attachment.get("InstanceId")
        result.append({
            "NetworkInterfaceId": eni_id,
            "SubnetId": subnet_id,
            "PrivateIpAddress": private_ip,
            "PublicIpAddress": public_ip,
            "Description": description,
            "Status": status,
            "InstanceId": instance_id
        })
    return result
