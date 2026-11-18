#!/usr/bin/env bash
# Creates the AWS side of the lab with Terraform, stack by stack: the state
# bucket, the network and the EKS cluster with a system node group and a GPU
# node group (3x g5.xlarge). Then writes the lab's own kubeconfig.
# Billable from here on: run teardown.sh (run-all.sh does it on exit).
set -euo pipefail
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ensure_clis
: > "${OUT}/assertions.txt"

step "identity"
aws sts get-caller-identity --query '[Account,Arn]' --output text | show

step "00-remote-backend (local state)"
tf_init 00-remote-backend
tf 00-remote-backend apply -input=false -no-color -auto-approve > "${OUT}/apply-00.log"
tail -1 "${OUT}/apply-00.log" | show

remote_backend_vars
step "01-networking"
tf_init 01-networking
tf 01-networking apply -input=false -no-color -auto-approve > "${OUT}/apply-01.log"
tail -1 "${OUT}/apply-01.log" | show

step "02-eks (control plane, system and GPU node groups): about 15 minutes"
TF_VAR_api_access="$(jq -cn --arg c "$(operator_cidr)" '{public_access_cidrs: [$c]}')"
export TF_VAR_api_access
tf_init 02-eks
tf 02-eks apply -input=false -no-color -auto-approve > "${OUT}/apply-02.log"
tail -1 "${OUT}/apply-02.log" | show

step "GPU node group: no AZ rebalancing"
# The GPU node group spans four AZs for capacity; when on-demand capacity
# lands all nodes in one AZ, the Auto Scaling group later rebalances: it
# launches nodes elsewhere and terminates the ones serving the model (seen in
# this lab's first run, two vLLM replicas gone mid-measurement). The lab keeps
# its nodes where they are.
gpu_asg="$(aws autoscaling describe-auto-scaling-groups --region "${AWS_REGION}" \
  --filters "Name=tag:eks:nodegroup-name,Values=eks-node-group-gpu-infergw" \
  --query 'AutoScalingGroups[0].AutoScalingGroupName' --output text)"
aws autoscaling suspend-processes --region "${AWS_REGION}" --auto-scaling-group-name "${gpu_asg}" --scaling-processes AZRebalance
note "AZRebalance suspended on ${gpu_asg}"

step "kubeconfig (lab file only)"
aws eks update-kubeconfig --region "${AWS_REGION}" --name "${EKS_CLUSTER}" --alias "${KUBE_CONTEXT}" --kubeconfig "${KUBECONFIG}" >/dev/null
assert_lab_context
k get nodes -L lab.infergw/role,node.kubernetes.io/instance-type | show

step "checks"
gpus() { k get nodes -l lab.infergw/role=model -o jsonpath='{range .items[*]}{.status.allocatable.nvidia\.com/gpu}{"\n"}{end}' | grep -c '^1$' || true; }
gpus_ready() { [ "$(gpus)" = 3 ]; }
wait_until 300 gpus_ready || true
expect_eq "EKS version" "1.37" "$(aws eks describe-cluster --region "${AWS_REGION}" --name "${EKS_CLUSTER}" --query cluster.version --output text)"
expect_eq "nodes Ready (2 system + 3 GPU)" "5" "$(k get nodes --no-headers | awk '$2 == "Ready"' | wc -l | tr -d ' ')"
expect_eq "GPU nodes advertising one nvidia.com/gpu each (device plugin from the Bottlerocket NVIDIA AMI)" "3" "$(gpus)"
expect_eq "AZRebalance suspended on the GPU Auto Scaling group" "AZRebalance" \
  "$(aws autoscaling describe-auto-scaling-groups --region "${AWS_REGION}" --auto-scaling-group-names "${gpu_asg}" --query 'AutoScalingGroups[0].SuspendedProcesses[].ProcessName' --output text)"
expect_eq "GPU nodes are ${GPU_INSTANCE_TYPE}" "${GPU_INSTANCE_TYPE}" "$(k get nodes -l lab.infergw/role=model -o jsonpath='{range .items[*]}{.metadata.labels.node\.kubernetes\.io/instance-type}{"\n"}{end}' | sort -u | paste -sd' ' -)"
finish
