variable "tags" {
  description = "Global tags injected by the provider default_tags block. Resources only add Name (plus the discovery tags listed in the stack README)."
  type        = map(string)

  default = {
    "Project"   = "infergw"
    "Env"       = "lab"
    "region"    = "us-east-1"
    "ManagedBy" = "terraform"
  }
}

variable "assume_role" {
  description = "Region and optional role for the provider. The lab runs on the operator's credentials (AWS_PROFILE) with role_arn = null; set a role ARN to run through a delegated role."
  type = object({
    role_arn = string
    region   = string
  })

  default = {
    role_arn = null
    region   = "us-east-1"
  }
}

variable "remote_backend" {
  description = "Where the upstream stacks keep their state. bucket carries the account ID, so scripts/lib.sh sets it through TF_VAR_remote_backend."
  type = object({
    bucket = string
    region = string
  })

  default = {
    bucket = ""
    region = "us-east-1"
  }

  validation {
    condition     = var.remote_backend.bucket != ""
    error_message = "Set remote_backend.bucket (scripts/lib.sh exports TF_VAR_remote_backend)."
  }
}

variable "api_access" {
  description = "CIDRs allowed to reach the public EKS API endpoint: the operator running the lab. scripts/lib.sh sets it through TF_VAR_api_access."
  type = object({
    public_access_cidrs = list(string)
  })

  default = {
    public_access_cidrs = []
  }

  validation {
    condition     = length(var.api_access.public_access_cidrs) > 0 && !contains(var.api_access.public_access_cidrs, "0.0.0.0/0")
    error_message = "The EKS endpoint must be allow-listed: at least one CIDR, never 0.0.0.0/0."
  }
}

variable "eks" {
  description = "Cluster, node groups and access configuration. admin_principal_arn is the only IAM principal that gets Kubernetes cluster-admin; null means the identity running apply."
  type = object({
    cluster_name            = string
    cluster_version         = string
    cluster_iam_role_name   = string
    cluster_policy_arns     = list(string)
    node_iam_role_name      = string
    node_policy_arns        = list(string)
    authentication_mode     = string
    endpoint_public_access  = bool
    endpoint_private_access = bool
    admin_principal_arn     = string
    admin_access_policy_arn = string
    node_groups = map(object({
      name                = string
      all_private_subnets = bool
      instance_types      = list(string)
      ami_type            = string
      capacity_type       = string
      disk_size           = number
      desired_size        = number
      min_size            = number
      max_size            = number
      labels              = map(string)
      taints = list(object({
        key    = string
        value  = string
        effect = string
      }))
    }))
  })

  default = {
    cluster_name          = "eks-cluster-infergw"
    cluster_version       = "1.37"
    cluster_iam_role_name = "eks-cluster-iam-role-infergw"
    cluster_policy_arns = [
      "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    ]
    node_iam_role_name = "eks-node-iam-role-infergw"
    node_policy_arns = [
      "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
      "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPullOnly",
      "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    ]
    authentication_mode     = "API"
    endpoint_public_access  = true
    endpoint_private_access = true
    admin_principal_arn     = null
    admin_access_policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
    node_groups = {
      system = {
        name                = "eks-node-group-system-infergw"
        all_private_subnets = false
        instance_types      = ["t4g.large"]
        ami_type            = "AL2023_ARM_64_STANDARD"
        capacity_type       = "ON_DEMAND"
        disk_size           = 20
        desired_size        = 2
        min_size            = 2
        max_size            = 2
        labels              = { "lab.infergw/role" = "platform" }
        taints              = []
      }
      gpu = {
        name                = "eks-node-group-gpu-infergw"
        all_private_subnets = true
        # One GPU with 24 GB per node, one vLLM replica each. The lab was
        # planned on g6.xlarge (1x NVIDIA L4); during its first run on-demand
        # g6.xlarge and g6.2xlarge capacity was exhausted in four AZs of
        # us-east-1 (InsufficientInstanceCapacity), and it ran on g5.xlarge
        # (1x NVIDIA A10G, 24 GB) instead. One type only, so every replica
        # has the same GPU. Both are in the Bottlerocket NVIDIA AMI's list.
        instance_types = ["g5.xlarge"]
        ami_type       = "BOTTLEROCKET_x86_64_NVIDIA"
        capacity_type  = "ON_DEMAND"
        # Bottlerocket keeps images on its data volume: the vLLM image is
        # large and the model weights are downloaded at start.
        disk_size    = 100
        desired_size = 3
        min_size     = 3
        max_size     = 3
        labels       = { "lab.infergw/role" = "model" }
        taints = [
          {
            key    = "nvidia.com/gpu"
            value  = "true"
            effect = "NO_SCHEDULE"
          },
        ]
      }
    }
  }
}
