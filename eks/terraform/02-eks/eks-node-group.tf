# Two managed node groups on the private subnets:
#   system: istiod, the Istio gateway, the Endpoint Picker, CoreDNS and the
#           load generator;
#   gpu:    one vLLM replica per node. Bottlerocket NVIDIA AMI: the NVIDIA
#           driver, container toolkit and the NVIDIA Kubernetes device plugin
#           ship with the AMI (EKS user guide, "Use EKS-optimized accelerated
#           AMIs"), so nodes advertise nvidia.com/gpu without anything to
#           install. The taint keeps everything else off the GPUs.

resource "aws_eks_node_group" "this" {
  for_each = var.eks.node_groups

  cluster_name    = aws_eks_cluster.this.name
  node_group_name = each.value.name
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = each.value.all_private_subnets ? local.private_subnet_ids : local.cluster_subnet_ids
  instance_types  = each.value.instance_types
  ami_type        = each.value.ami_type
  capacity_type   = each.value.capacity_type
  disk_size       = each.value.disk_size
  labels          = each.value.labels

  scaling_config {
    desired_size = each.value.desired_size
    min_size     = each.value.min_size
    max_size     = each.value.max_size
  }

  dynamic "taint" {
    for_each = each.value.taints

    content {
      key    = taint.value.key
      value  = taint.value.value
      effect = taint.value.effect
    }
  }

  tags = {
    Name = each.value.name
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
