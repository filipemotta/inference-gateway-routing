#!/usr/bin/env bash
# Removes everything the EKS lab created: the Terraform stacks in reverse
# (EKS and its node groups, the network, the state bucket), the network
# interfaces the VPC CNI can leave behind, and then looks independently for
# anything left: instances, volumes, interfaces, Elastic IPs, NAT gateways,
# load balancers, the VPC, IAM roles, the cluster and the state bucket.
# Only resources carrying this lab's names and tags are touched.
# Exits non-zero if anything is left.
set -uo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB_VPC="$(aws ec2 describe-vpcs --region "${AWS_REGION}" --filters Name=tag:Project,Values=infergw --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
note "lab VPC: ${LAB_VPC}"

remote_backend_vars
if aws s3api head-bucket --bucket "$(aws_state_bucket)" >/dev/null 2>&1; then
  step "node group Auto Scaling groups to zero"
  # Seen in this lab's first run: a GPU node group whose Auto Scaling group
  # kept retrying launches (InsufficientInstanceCapacity) stayed in DELETING
  # for 27 minutes and finished seconds after its group was set to zero.
  for asg in $(aws autoscaling describe-auto-scaling-groups --region "${AWS_REGION}" \
      --filters "Name=tag:eks:cluster-name,Values=${EKS_CLUSTER}" \
      --query 'AutoScalingGroups[].AutoScalingGroupName' --output text 2>/dev/null); do
    note "${asg}"
    aws autoscaling update-auto-scaling-group --region "${AWS_REGION}" --auto-scaling-group-name "${asg}" \
      --min-size 0 --desired-capacity 0 || true
  done
  step "02-eks"
  export TF_VAR_api_access='{"public_access_cidrs":["127.0.0.1/32"]}'
  tf_init 02-eks
  if ! tf 02-eks destroy -input=false -no-color -auto-approve > "${OUT}/destroy-02.log" 2>&1; then
    tail -15 "${OUT}/destroy-02.log" | show
    fail "02-eks destroy failed: network and state bucket are kept, run teardown.sh again"
    finish
    exit 1
  fi
  tail -1 "${OUT}/destroy-02.log" | show
  if [ -n "${LAB_VPC}" ] && [ "${LAB_VPC}" != "None" ]; then
    step "network interfaces the VPC CNI left behind"
    for eni in $(aws ec2 describe-network-interfaces --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=${LAB_VPC}" Name=status,Values=available "Name=description,Values=aws-K8S-*" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text); do
      note "deleting ${eni}"
      aws ec2 delete-network-interface --region "${AWS_REGION}" --network-interface-id "${eni}" || true
    done
    for sg in $(aws ec2 describe-security-groups --region "${AWS_REGION}" \
        --filters "Name=vpc-id,Values=${LAB_VPC}" "Name=group-name,Values=eks-cluster-sg-${EKS_CLUSTER}-*" \
        --query 'SecurityGroups[].GroupId' --output text); do
      note "deleting ${sg}"
      aws ec2 delete-security-group --region "${AWS_REGION}" --group-id "${sg}" || true
    done
  fi
  step "01-networking"
  tf_init 01-networking
  if ! tf 01-networking destroy -input=false -no-color -auto-approve > "${OUT}/destroy-01.log" 2>&1; then
    tail -15 "${OUT}/destroy-01.log" | show
    fail "01-networking destroy failed: the state bucket is kept, fix the leftover and run teardown.sh again"
    finish
    exit 1
  fi
  tail -1 "${OUT}/destroy-01.log" | show
fi
if [ -f "${EKS_ROOT}/terraform/00-remote-backend/terraform.tfstate" ]; then
  step "00-remote-backend"
  tf_init 00-remote-backend && tf 00-remote-backend destroy -input=false -no-color -auto-approve > "${OUT}/destroy-00.log" 2>&1
  tail -1 "${OUT}/destroy-00.log" | show
fi
rm -f "${KUBECONFIG}"

step "leftovers (independent of Terraform state)"
q() { aws "$@" --region "${AWS_REGION}" --output text 2>/dev/null || echo "?"; }
expect_eq "EKS cluster gone" "0" "$(q eks list-clusters --query "length(clusters[?@=='${EKS_CLUSTER}'])")"
expect_eq "no lab instances left (any state but terminated)" "0" \
  "$(q ec2 describe-instances --filters "Name=tag:eks:cluster-name,Values=${EKS_CLUSTER}" "Name=instance-state-name,Values=pending,running,stopping,stopped,shutting-down" --query 'length(Reservations[].Instances[])')"
expect_eq "no lab volumes left" "0" "$(q ec2 describe-volumes --filters "Name=tag:eks:cluster-name,Values=${EKS_CLUSTER}" --query 'length(Volumes)')"
expect_eq "no lab Elastic IPs left" "0" "$(q ec2 describe-addresses --filters Name=tag:Project,Values=infergw --query 'length(Addresses)')"
expect_eq "no lab NAT gateways left (not deleted)" "0" \
  "$(q ec2 describe-nat-gateways --filter Name=tag:Project,Values=infergw Name=state,Values=pending,available,deleting,failed --query 'length(NatGateways)')"
expect_eq "no lab VPC left" "0" "$(q ec2 describe-vpcs --filters Name=tag:Project,Values=infergw --query 'length(Vpcs)')"
if [ -n "${LAB_VPC}" ] && [ "${LAB_VPC}" != "None" ]; then
  expect_eq "no network interfaces left in the lab VPC" "0" "$(q ec2 describe-network-interfaces --filters "Name=vpc-id,Values=${LAB_VPC}" --query 'length(NetworkInterfaces)')"
  expect_eq "no load balancers left in the lab VPC" "0" "$(q elbv2 describe-load-balancers --query "length(LoadBalancers[?VpcId=='${LAB_VPC}'])")"
fi
expect_eq "no lab IAM roles left" "0" "$(aws iam list-roles --query "length(Roles[?contains(RoleName, 'infergw')])" --output text 2>/dev/null || echo "?")"
expect_eq "state bucket gone" "absent" "$(aws s3api head-bucket --bucket "$(aws_state_bucket)" >/dev/null 2>&1 && echo present || echo absent)"
finish
