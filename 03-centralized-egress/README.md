## Centralized Egress Architecture

![Alt text](../images/centralized-egress.drawio.svg?raw=true "Centralized Egress Internet Architecture")<br>

1. Traffic from the lambda function in the private subnet attempts to reach the internet, the subnet's route table routes to transit gateway (0.0.0.0/0)
2. Traffic enters transit gateway on the transit gateway attachment and it's routed to the egress VPC via the route table in transit gateway
3. Traffic enters the egress VPC on the transit gateway attachment subnet
4. The subnet's route table routes the traffic to the NAT gateway, then the source IP is changed to NAT gateway IP
5. After exiting the NAT gateway, the traffic looks up the public subnet route table then get routed to internet gateway

References:

- https://aws.amazon.com/blogs/networking-and-content-delivery/creating-a-single-internet-exit-point-from-multiple-vpcs-using-aws-transit-gateway/
- https://docs.aws.amazon.com/whitepapers/latest/building-scalable-secure-multi-vpc-network-infrastructure/centralized-egress-to-internet.html

## Deploy

```
$ terraform init
$ terraform plan
$ terraform apply -auto-approve
```

## Testing

Run each lambda function via AWS CLI to test whether the lambda can reach the internet (GitHub API `https://api.github.com/`):

```bash
# Test Spoke 1 Lambda (app1):
aws lambda invoke --function-name app1 --region us-east-2 response-app1.json
cat response-app1.json # or type response-app1.json on Windows

# Test Spoke 2 Lambda (app2):
aws lambda invoke --function-name app2 --region us-east-2 response-app2.json
cat response-app2.json # or type response-app2.json on Windows
```

Expected output:
```json
{"statusCode": 200, "body": "{\"url\": \"https://api.github.com/\", \"status\": 200}"}
```

CloudWatch Logs output will show:
```
START RequestId: ... Version: $LATEST
https://api.github.com/
200
END RequestId: ...
REPORT RequestId: ... Duration: 33.74 ms ...
```

