## Centralized VPC Endpoint Architecture

![Alt text](../images/centralized-vpce.drawio.svg?raw=true "ECS Deployment Architecture")<br>

1. Spoke VPC 1, 2 and the central VPC are peered with transit gateway
2. Spoke VPC 1, 2, and the central VPC need to be associated with Route 53 private hosted zone, make sure the private DNS resolution endpoint creation disabled
3. The spoke VPC 1 & 2 will resolve the VPC endpoints in Route 53 private hosted zone
4. Some consideration for endpoint policy is limited with 20480 characters, let's say if you have a lot VPCs need to use this central endpoints
5. Make sure you have enough a pool of IP addresses, when there are spikes of network traffic, the VPC endpoints nodes will scale out (automatically)

References:

- https://aws.amazon.com/blogs/networking-and-content-delivery/centralize-access-using-vpc-interface-endpoints/
- https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/centralized-access-to-vpc-private-endpoints.html

## Purpose

- Cost saving for having small number of VPC endpoints
- Security compliance by using private link communication with AWS services

## Prerequisites
- Apply the terraform state bucket in `00-infra-bucket`
- Create `backend.config`, update the configuration based on your needs
```
bucket = "s3-backend-tfstate-xxxxxx"
key = "dev/centralized-vpce.tfstate"
region = "your-region"
encrypt = true
use_lockfile = true
profile = "your-profilename"
```

## Deploy

```
$ terraform init -backend-config=backend.config
$ terraform plan -var-file=terraform.tfvars # use .tfvars if any
$ terraform apply -var-file=terraform.tfvars -auto-approve # use .tfvars if any
```

## Testing

1. Connect to both EC2 instances using AWS Systems Manager (Session Manager):
```bash
aws ssm start-session --target <SPOKE1_INSTANCE_ID> --region us-east-1
aws ssm start-session --target <SPOKE2_INSTANCE_ID> --region us-east-1
```

2. Inside the Spoke EC2 instance, test DNS resolution of centralized VPC endpoints:
```bash
nslookup ssm.us-east-1.amazonaws.com
nslookup s3.us-east-1.amazonaws.com
```
*Expected Output:* The command returns **2 Private IP addresses** belonging to the VPC Interface Endpoints located in the Hub VPC (one per AZ). This verifies that the Spoke VPC resolves the endpoints via Route 53 Private Hosted Zone across Transit Gateway without internet exposure.

3. Verify instances private IPs from your local machine:
```bash
aws ec2 describe-instances --filters "Name=tag:Name,Values=spoke*" --query "Reservations[].Instances[].[Tags[?Key=='Name'].Value|[0], PrivateIpAddress]" --output table
```
