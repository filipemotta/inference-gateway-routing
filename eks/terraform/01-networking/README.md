# aws/01-networking

## Purpose
The AWS network of the lab: VPC `10.10.0.0/16`, public subnets in two AZs, private subnets in four AZs, one NAT gateway.

## Provisions
- `aws_vpc.main`, `aws_internet_gateway.this`
- `aws_subnet.public[*]` (us-east-1a, 1b), `aws_subnet.private[*]` (us-east-1a, 1b, 1c, 1d), the route tables and their associations
- `aws_eip.this` + `aws_nat_gateway.this` (single NAT: lab cost)

## Consumes
- nothing

## Provides
- `vpc`, `public_subnets_ids`, `private_subnets_ids`, `nat_gateway`, `nat_public_ip`

## Notes
- The first two private subnets host the EKS control plane interfaces and the system nodes; all four host the GPU node group, so the Auto Scaling group can launch g6.xlarge in an AZ that has capacity.
- Discovery tags (beyond `Name`): `kubernetes.io/role/elb` on public subnets, `kubernetes.io/role/internal-elb` on private subnets, `kubernetes.io/cluster/eks-cluster-infergw = shared` on both.
