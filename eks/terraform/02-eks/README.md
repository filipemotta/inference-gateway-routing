# aws/02-eks

## Purpose
EKS 1.37 with a public API endpoint allow-listed to the operator's address, a small managed node group for system pods and a GPU managed node group for the model servers.

## Provisions
- `aws_eks_cluster.this` on the first two private subnets of `01-networking`
- `aws_eks_node_group.this["system"]`: 2x t4g.large, `AL2023_ARM_64_STANDARD`, label `lab.infergw/role=platform` (istiod, the Istio gateway, the Endpoint Picker, the load generator)
- `aws_eks_node_group.this["gpu"]`: 3x g5.xlarge (1x NVIDIA A10G, 24 GB, each; planned on g6.xlarge, see the comment in `variables.tf`), `BOTTLEROCKET_x86_64_NVIDIA` (driver, container toolkit and NVIDIA device plugin come with the AMI), 100 GB disk, label `lab.infergw/role=model`, taint `nvidia.com/gpu=true:NoSchedule`, on all four private subnets
- `aws_iam_role.cluster`, `aws_iam_role.node` and their managed policy attachments
- `aws_eks_access_entry.admin` + `aws_eks_access_policy_association.admin` (the only cluster-admin; creator admin bootstrap is off)

## Consumes
- `01-networking` state (`terraform_remote_state`): VPC and subnet IDs

## Provides
- `eks_cluster`, `cluster_name`, `node_groups`, `cluster_iam_role_arn`, `node_iam_role_arn`

## Notes
- `TF_VAR_api_access` (set by `scripts/00-infra.sh`) is the operator's /32; `0.0.0.0/0` is rejected by validation.
- Istio, the Endpoint Picker and vLLM are installed by the scripts, not by Terraform.
