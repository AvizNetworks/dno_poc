from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
import boto3
from typing import List, Optional
import paramiko
import json
import os
from datetime import datetime


app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://10.4.5.243:8080"], 
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

PEM_FILE_PATH = "asn-aws.pem"
DEPLOYED_NODES_FILE = "deployed_nodes.json"

class DeployInstanceRequest(BaseModel):
    region: str
    vpc_id: str
    ami_id: str
    instance_type: str
    key_name: Optional[str] = None
    subnet_id: Optional[str] = None  


class MirrorRequest(BaseModel):
    region: str
    source_instance_id: str
    target_instance_id: str
    target_eni: Optional[str] = None
    protocol: Optional[int] = 1  
    directions: Optional[List[str]] = ["ingress", "egress"]

class InstanceActionRequest(BaseModel):
    region: str
    instance_ids: List[str] 

class ASNDeployRequest(BaseModel):
    region: str
    vpc_id: str
    instance_id: str

class ASNStopRequest(BaseModel):
    instance_id: str

def load_deployed_nodes():
    if os.path.exists(DEPLOYED_NODES_FILE):
        with open(DEPLOYED_NODES_FILE, 'r') as f:
            return json.load(f)
    return []

def save_deployed_nodes(nodes):
    with open(DEPLOYED_NODES_FILE, 'w') as f:
        json.dump(nodes, f, indent=2)

def ssh_command(hostname, username, pem_path, command):
    ssh = paramiko.SSHClient()
    ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    
    try:
        private_key = paramiko.RSAKey.from_private_key_file(pem_path)
        ssh.connect(hostname, username=username, pkey=private_key, timeout=30)
        
        stdin, stdout, stderr = ssh.exec_command(command)
        output = stdout.read().decode()
        error = stderr.read().decode()
        
        return {
            'success': True,
            'output': output,
            'error': error
        }
    except Exception as e:
        return {
            'success': False,
            'error': str(e)
        }
    finally:
        ssh.close()

@app.get("/regions", response_model=List[str])
def list_regions():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    regions = ec2.describe_regions()["Regions"]
    return [r["RegionName"] for r in regions]

@app.get("/topology", response_model=dict)
def get_bulk_topology(region: str):
    ec2 = boto3.client("ec2", region_name=region)
    
    vpcs_response = ec2.describe_vpcs()
    subnets_response = ec2.describe_subnets()
    instances_response = ec2.describe_instances()
    
    vpcs_data = {}
    for vpc in vpcs_response["Vpcs"]:
        vpc_id = vpc["VpcId"]
        name = next((tag["Value"] for tag in vpc.get("Tags", []) if tag["Key"] == "Name"), None)
        vpcs_data[vpc_id] = {
            "VpcId": vpc_id,
            "Name": name,
            "Subnets": {}
        }
    
    for subnet in subnets_response["Subnets"]:
        vpc_id = subnet["VpcId"]
        subnet_id = subnet["SubnetId"]
        name = next((tag["Value"] for tag in subnet.get("Tags", []) if tag["Key"] == "Name"), None)
        
        if vpc_id in vpcs_data:
            vpcs_data[vpc_id]["Subnets"][subnet_id] = {
                "SubnetId": subnet_id,
                "Name": name,
                "CidrBlock": subnet.get("CidrBlock"),
                "AvailableIpAddressCount": subnet.get("AvailableIpAddressCount"),
                "Instances": [],
                "InstanceCounts": {
                    "total": 0,
                    "running": 0,
                    "stopped": 0
                }
            }
    
    for reservation in instances_response["Reservations"]:
        for instance in reservation["Instances"]:
            subnet_id = instance.get("SubnetId")
            vpc_id = instance.get("VpcId")
            
            if vpc_id in vpcs_data and subnet_id in vpcs_data[vpc_id]["Subnets"]:
                name = next((tag["Value"] for tag in instance.get("Tags", []) if tag["Key"] == "Name"), None)
                state = instance.get("State", {}).get("Name", "unknown").lower()
                launch_time = instance.get("LaunchTime")
                
                instance_data = {
                    "InstanceId": instance["InstanceId"],
                    "Name": name or instance["InstanceId"],
                    "PrivateIpAddress": instance.get("PrivateIpAddress", "-"),
                    "PublicIpAddress": instance.get("PublicIpAddress", "-"),
                    "State": state,
                    "LaunchTime": launch_time.isoformat() if launch_time else None
                }
                
                vpcs_data[vpc_id]["Subnets"][subnet_id]["Instances"].append(instance_data)
                
                counts = vpcs_data[vpc_id]["Subnets"][subnet_id]["InstanceCounts"]
                counts["total"] += 1
                if state == "running":
                    counts["running"] += 1
                elif state == "stopped":
                    counts["stopped"] += 1
    
    return {
        "Region": region,
        "VPCs": list(vpcs_data.values())
    }

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
        
        cidr = v.get("CidrBlock")

        cidr_blocks = [
            assoc["CidrBlock"]
            for assoc in v.get("CidrBlockAssociationSet", [])
            if assoc["CidrBlockState"]["State"] == "associated"
        ]

        result.append({
            "VpcId": vpc_id,
            "Name": name,
            "CidrBlock": cidr,                 
            "CidrBlocks": cidr_blocks          
        })

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

@app.post("/instances/start")
def start_instances(req: InstanceActionRequest):
    try:
        ec2 = boto3.client("ec2", region_name=req.region)
        if not req.instance_ids:
            raise HTTPException(400, detail="No instance IDs provided")
        resp = ec2.start_instances(InstanceIds=req.instance_ids)
        return {
            "status": "success",
            "action": "start",
            "instances": req.instance_ids,
            "response": resp
        }
    except Exception as e:
        raise HTTPException(500, detail=str(e))


@app.post("/instances/stop")
def stop_instances(req: InstanceActionRequest):
    try:
        ec2 = boto3.client("ec2", region_name=req.region)
        if not req.instance_ids:
            raise HTTPException(400, detail="No instance IDs provided")
        resp = ec2.stop_instances(InstanceIds=req.instance_ids)
        return {
            "status": "success",
            "action": "stop",
            "instances": req.instance_ids,
            "response": resp
        }
    except Exception as e:
        raise HTTPException(500, detail=str(e))

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
            state = instance.get("State", {}).get("Name")
            launch_time = instance.get("LaunchTime")
            
            result.append({
                "InstanceId": instance_id,
                "Name": name,
                "PrivateIpAddress": private_ip,
                "PublicIpAddress": public_ip,
                "State": state,
                "LaunchTime": launch_time.isoformat() if launch_time else None
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

@app.post("/mirror")
def setup_mirroring(req: MirrorRequest):
    try:
        ec2 = boto3.client("ec2", region_name=req.region)

        def get_primary_eni(instance_id):
            try:
                resp = ec2.describe_instances(InstanceIds=[instance_id])
                instance = resp["Reservations"][0]["Instances"][0]
                enis = instance["NetworkInterfaces"]

                primary_eni = None
                for eni in enis:
                    if eni["Attachment"]["DeviceIndex"] == 0:
                        primary_eni = eni
                        break
                if not primary_eni:
                    primary_eni = enis[0]

                return (
                    primary_eni["NetworkInterfaceId"],
                    instance["PrivateIpAddress"],
                    primary_eni["VpcId"]
                )
            except Exception as e:
                raise HTTPException(500, f"Error retrieving ENI for {instance_id}: {e}")

        source_eni, source_ip, vpc_id = get_primary_eni(req.source_instance_id)

        if req.target_eni:
            target_eni = req.target_eni
            print(f"Using user-selected target ENI: {target_eni}")
        else:
            target_eni, _, _ = get_primary_eni(req.target_instance_id)
            print(f"Using primary ENI as target: {target_eni}")
        
        vpc_resp = ec2.describe_vpcs(VpcIds=[vpc_id])
        vpc_cidr = vpc_resp["Vpcs"][0]["CidrBlock"] 

        filter_resp = ec2.create_traffic_mirror_filter(
            TagSpecifications=[{
                "ResourceType": "traffic-mirror-filter",
                "Tags": [{"Key": "Name", "Value": f"MirrorFilter-{req.source_instance_id}"}]
            }]
        )
        filter_id = filter_resp["TrafficMirrorFilter"]["TrafficMirrorFilterId"]

        rule_number = 100
        for direction in req.directions:
            if direction.lower() == "ingress":
                ec2.create_traffic_mirror_filter_rule(
                    TrafficMirrorFilterId=filter_id,
                    TrafficDirection="ingress",
                    RuleNumber=rule_number,
                    RuleAction="accept",
                    Protocol=req.protocol,
                    SourceCidrBlock=vpc_cidr,
                    DestinationCidrBlock=vpc_cidr
                )
            elif direction.lower() == "egress":
                ec2.create_traffic_mirror_filter_rule(
                    TrafficMirrorFilterId=filter_id,
                    TrafficDirection="egress",
                    RuleNumber=rule_number,
                    RuleAction="accept",
                    Protocol=req.protocol,
                    SourceCidrBlock=vpc_cidr,
                    DestinationCidrBlock=vpc_cidr
                )
            rule_number += 1

        existing_targets = ec2.describe_traffic_mirror_targets()["TrafficMirrorTargets"]
        target_id = None

        for target in existing_targets:
            if target.get("NetworkInterfaceId") == target_eni:
                target_id = target["TrafficMirrorTargetId"]
                print(f"Reusing existing target: {target_id} for ENI {target_eni}")
                break

        if not target_id:
            target_resp = ec2.create_traffic_mirror_target(
                NetworkInterfaceId=target_eni,
                TagSpecifications=[{
                    "ResourceType": "traffic-mirror-target",
                    "Tags": [{"Key": "Name", "Value": f"MirrorTarget-{req.target_instance_id}"}]
                }]
            )
            target_id = target_resp["TrafficMirrorTarget"]["TrafficMirrorTargetId"]
            print(f"Created new target: {target_id} for ENI {target_eni}")

        existing_sessions = ec2.describe_traffic_mirror_sessions(
            Filters=[{"Name": "network-interface-id", "Values": [source_eni]}]
        )["TrafficMirrorSessions"]

        session_numbers = [s["SessionNumber"] for s in existing_sessions]
        session_number = max(session_numbers, default=0) + 1
        if session_number > 32766:
            raise HTTPException(400, "No available session number for this ENI")

        ec2.create_traffic_mirror_session(
            NetworkInterfaceId=source_eni,
            TrafficMirrorTargetId=target_id,
            TrafficMirrorFilterId=filter_id,
            SessionNumber=session_number,
            TagSpecifications=[{
                "ResourceType": "traffic-mirror-session",
                "Tags": [{"Key": "Name", "Value": f"MirrorSession-{req.source_instance_id}"}]
            }]
        )

        return {
            "status": "success",
            "region": req.region,
            "vpc_id": vpc_id,
            "vpc_cidr": vpc_cidr,
            "source_instance_id": req.source_instance_id,
            "target_instance_id": req.target_instance_id,
            "source_ip": source_ip,
            "source_eni": source_eni,
            "target_eni": target_eni,
            "filter_id": filter_id,
            "target_id": target_id,
            "session_number": session_number
        }

    except HTTPException:
        raise
    except Exception as e:
        print(f"ERROR in /mirror endpoint: {str(e)}")
        import traceback
        traceback.print_exc()
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/filters")
def list_mirror_filters(region: str):
    try:
        ec2 = boto3.client("ec2", region_name=region)

        filters_resp = ec2.describe_traffic_mirror_filters()
        rules_resp = ec2.describe_traffic_mirror_filter_rules()
        sessions_resp = ec2.describe_traffic_mirror_sessions()

        eni_to_instance = {}
        enis = ec2.describe_network_interfaces()
        for eni in enis.get("NetworkInterfaces", []):
            eni_id = eni["NetworkInterfaceId"]
            if "Attachment" in eni and "InstanceId" in eni["Attachment"]:
                eni_to_instance[eni_id] = eni["Attachment"]["InstanceId"]
            else:
                eni_to_instance[eni_id] = eni_id

        filters_list = []

        for f in filters_resp.get("TrafficMirrorFilters", []):
            filter_id = f.get("TrafficMirrorFilterId")
            description = f.get("Description")
            network_services = f.get("NetworkServices", [])

            filter_rules = [
                {
                    "RuleId": r.get("TrafficMirrorFilterRuleId"),
                    "Direction": r.get("TrafficDirection"),
                    "Protocol": r.get("Protocol"),
                    "SourceCidr": r.get("SourceCidrBlock"),
                    "DestinationCidr": r.get("DestinationCidrBlock"),
                    "Action": r.get("RuleAction"),
                    "RuleNumber": r.get("RuleNumber")
                }
                for r in rules_resp.get("TrafficMirrorFilterRules", [])
                if r.get("TrafficMirrorFilterId") == filter_id
            ]

            sessions = []
            for s in sessions_resp.get("TrafficMirrorSessions", []):
                if s.get("TrafficMirrorFilterId") != filter_id:
                    continue

                source_eni = s.get("NetworkInterfaceId")
                source_instance = eni_to_instance.get(source_eni, source_eni)

                sessions.append({
                    "SessionId": s.get("TrafficMirrorSessionId"),
                    "SourceInstanceId": source_instance,
                    "SourceEni": source_eni,
                    "TargetId": s.get("TrafficMirrorTargetId"),
                    "SessionNumber": s.get("SessionNumber")
                })

            filters_list.append({
                "FilterId": filter_id,
                "Description": description,
                "NetworkServices": network_services,
                "Rules": filter_rules,
                "Sessions": sessions
            })

        return filters_list

    except Exception as e:
        print("ERROR IN /filters:", e)
        raise HTTPException(status_code=500, detail=str(e))


@app.delete("/filters/{session_id}")
def delete_mirror_session(session_id: str, region: str):
    try:
        ec2 = boto3.client("ec2", region_name=region)

        resp = ec2.describe_traffic_mirror_sessions(TrafficMirrorSessionIds=[session_id])
        sessions = resp.get("TrafficMirrorSessions", [])

        if not sessions:
            raise HTTPException(404, f"Session {session_id} not found")

        session = sessions[0]
        target_id = session["TrafficMirrorTargetId"]
        filter_id = session["TrafficMirrorFilterId"]

        ec2.delete_traffic_mirror_session(TrafficMirrorSessionId=session_id)

        import time
        time.sleep(2) 

        all_sessions = ec2.describe_traffic_mirror_sessions().get("TrafficMirrorSessions", [])

        target_in_use = any(s["TrafficMirrorTargetId"] == target_id for s in all_sessions)

        if not target_in_use:
            ec2.delete_traffic_mirror_target(TrafficMirrorTargetId=target_id)

        filter_in_use = any(s["TrafficMirrorFilterId"] == filter_id for s in all_sessions)

        if not filter_in_use:
            ec2.delete_traffic_mirror_filter(TrafficMirrorFilterId=filter_id)

            rules = ec2.describe_traffic_mirror_filter_rules(
                Filters=[{"Name": "traffic-mirror-filter-id", "Values": [filter_id]}]
            ).get("TrafficMirrorFilterRules", [])

            for r in rules:
                ec2.delete_traffic_mirror_filter_rule(
                    TrafficMirrorFilterRuleId=r["TrafficMirrorFilterRuleId"]
                )

        return {
            "session_deleted": True,
            "target_deleted": not target_in_use,
            "filter_deleted": not filter_in_use
        }

    except Exception as e:
        print("Delete error:", e)
        raise HTTPException(500, str(e))

@app.post("/asn/deploy")
def deploy_asn(req: ASNDeployRequest):
    try:
        ec2 = boto3.client("ec2", region_name=req.region)
        response = ec2.describe_instances(InstanceIds=[req.instance_id])
        
        if not response["Reservations"] or not response["Reservations"][0]["Instances"]:
            raise HTTPException(404, detail="Instance not found")
        
        instance = response["Reservations"][0]["Instances"][0]
        public_ip = instance.get("PublicIpAddress")
        private_ip = instance.get("PrivateIpAddress")
        
        if not public_ip:
            raise HTTPException(400, detail="Instance has no public IP address")
        
        ip_dashed = public_ip.replace(".", "-")
        if req.region == "us-east-1":
            hostname = f"ec2-{ip_dashed}.compute-1.amazonaws.com"
        else:
            hostname = f"ec2-{ip_dashed}.{req.region}.compute.amazonaws.com"
        
        print(f"Connecting to {hostname}...")
        result = ssh_command(
            hostname=hostname,
            username='ubuntu',
            pem_path=PEM_FILE_PATH,
            command='sudo systemctl start asn-core && sudo systemctl status asn-core'
        )
        
        if not result['success']:
            raise HTTPException(500, detail=f"SSH connection failed: {result['error']}")
        
        if 'active (running)' not in result['output'] and 'Active: active' not in result['output']:
            raise HTTPException(500, detail=f"ASN service failed to start. Output: {result['output']}")
        
        name = next((tag["Value"] for tag in instance.get("Tags", []) if tag["Key"] == "Name"), None)
        
        deployed_node = {
            "id": req.instance_id,
            "name": name or f"Virtual Aviz Service Node ({req.instance_id})",
            "region": req.region,
            "vpc": req.vpc_id,
            "ip": private_ip,
            "publicIp": public_ip,
            "status": "Running",
            "deployedAt": datetime.now().isoformat(),
            "hostname": hostname
        }
        
        nodes = load_deployed_nodes()
        
        existing_index = next((i for i, n in enumerate(nodes) if n["id"] == req.instance_id), None)
        if existing_index is not None:
            nodes[existing_index] = deployed_node
        else:
            nodes.append(deployed_node)
        
        save_deployed_nodes(nodes)
        
        return {
            "success": True,
            "message": "ASN deployed and started successfully",
            "node": deployed_node,
            "output": result['output']
        }
    
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in /asn/deploy: {str(e)}")
        import traceback
        traceback.print_exc()
        raise HTTPException(500, detail=str(e))

@app.post("/asn/stop")
def stop_asn(req: ASNStopRequest):
    try:
        nodes = load_deployed_nodes()
        node = next((n for n in nodes if n["id"] == req.instance_id), None)
        
        if not node:
            raise HTTPException(404, detail="Node not found in deployed list")
        
        print(f"Stopping ASN on {node['hostname']}...")
        result = ssh_command(
            hostname=node['hostname'],
            username='ubuntu',
            pem_path=PEM_FILE_PATH,
            command='sudo systemctl stop asn-core && sudo systemctl status asn-core'
        )
        
        if not result['success']:
            raise HTTPException(500, detail=f"SSH connection failed: {result['error']}")
        
        for n in nodes:
            if n["id"] == req.instance_id:
                n["status"] = "Stopped"
                break
        
        save_deployed_nodes(nodes)
        
        return {
            "success": True,
            "message": "ASN stopped successfully",
            "output": result['output']
        }
    
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in /asn/stop: {str(e)}")
        raise HTTPException(500, detail=str(e))

@app.post("/asn/delete")
def delete_asn(instance_id: str):
    try:
        nodes = load_deployed_nodes()
        
        node = next((n for n in nodes if n["id"] == instance_id), None)
        if not node:
            raise HTTPException(404, detail="Node not found in deployed list")
        
        nodes = [n for n in nodes if n["id"] != instance_id]
        
        save_deployed_nodes(nodes)
        
        return {
            "success": True,
            "message": f"Node {instance_id} removed from deployed list"
        }
    
    except HTTPException:
        raise
    except Exception as e:
        print(f"Error in /asn/delete: {str(e)}")
        raise HTTPException(500, detail=str(e))

@app.get("/asn/deployed")
def get_deployed_nodes():
    try:
        nodes = load_deployed_nodes()
        return nodes
    except Exception as e:
        print(f"Error in /asn/deployed: {str(e)}")
        raise HTTPException(500, detail=str(e))
