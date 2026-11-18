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

variable "vpc" {
  description = "Network layout. Subnets are ordered lists consumed with count; the first two private subnets share AZs with the two public ones, the others exist for the GPU node group."
  type = object({
    name                     = string
    cidr_block               = string
    enable_dns_support       = bool
    enable_dns_hostnames     = bool
    internet_gateway_name    = string
    nat_gateway_name         = string
    public_route_table_name  = string
    eks_cluster_name         = string
    private_route_table_name = string
    public_subnets = list(object({
      name                    = string
      cidr_block              = string
      availability_zone       = string
      map_public_ip_on_launch = bool
    }))
    private_subnets = list(object({
      name              = string
      cidr_block        = string
      availability_zone = string
    }))
  })

  default = {
    name                     = "vpc-infergw-useast1"
    cidr_block               = "10.10.0.0/16"
    enable_dns_support       = true
    enable_dns_hostnames     = true
    internet_gateway_name    = "igw-infergw-useast1"
    nat_gateway_name         = "nat-gateway-infergw-useast1"
    public_route_table_name  = "public-route-table-infergw-useast1"
    eks_cluster_name         = "eks-cluster-infergw"
    private_route_table_name = "private-route-table-infergw-useast1"
    public_subnets = [
      {
        name                    = "public-subnet-infergw-useast1a"
        cidr_block              = "10.10.0.0/24"
        availability_zone       = "us-east-1a"
        map_public_ip_on_launch = true
      },
      {
        name                    = "public-subnet-infergw-useast1b"
        cidr_block              = "10.10.1.0/24"
        availability_zone       = "us-east-1b"
        map_public_ip_on_launch = true
      },
    ]
    private_subnets = [
      {
        name              = "private-subnet-infergw-useast1a"
        cidr_block        = "10.10.10.0/24"
        availability_zone = "us-east-1a"
      },
      {
        name              = "private-subnet-infergw-useast1b"
        cidr_block        = "10.10.11.0/24"
        availability_zone = "us-east-1b"
      },
      # Extra AZs for the GPU node group only: g6.xlarge capacity in a single
      # AZ runs out (InsufficientInstanceCapacity in 1a and 1b during the
      # first run of this lab), and a node group spread over more AZs lets
      # the Auto Scaling group launch where there is capacity.
      {
        name              = "private-subnet-infergw-useast1c"
        cidr_block        = "10.10.12.0/24"
        availability_zone = "us-east-1c"
      },
      {
        name              = "private-subnet-infergw-useast1d"
        cidr_block        = "10.10.13.0/24"
        availability_zone = "us-east-1d"
      },
    ]
  }
}
