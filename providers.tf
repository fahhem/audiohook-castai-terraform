# Following providers required by EKS and VPC modules.
# 'aws' is provided by Zeet for us
# provider "aws" {
#   region = var.cluster_region
# }

locals {
  eks_cluster = data.aws_eks_cluster.existing_cluster
}

provider "castai" {
  api_url   = var.castai_api_url
  api_token = var.castai_api_token
}

# Import the existing cluster
data "aws_eks_cluster" "existing_cluster" {
  name = var.cluster_name
}
data "aws_subnets" "existing_cluster" {
  filter {
    name   = "vpc-id"
    values = [for vpc in data.aws_eks_cluster.existing_cluster.vpc_config : vpc.vpc_id]
  }
}

provider "kubernetes" {
  host                   = local.eks_cluster.endpoint
  cluster_ca_certificate = base64decode(local.eks_cluster.certificate_authority[0].data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # Zeet has the AWS profile named 'provider'
    args = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.cluster_region, "--profile", "provider"]
  }
}

provider "helm" {
  kubernetes {
    host                   = local.eks_cluster.endpoint
    cluster_ca_certificate = base64decode(local.eks_cluster.certificate_authority.0.data)
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # Zeet has the AWS profile named 'provider'
      args = ["eks", "get-token", "--cluster-name", var.cluster_name, "--region", var.cluster_region, "--profile", "provider"]
    }
  }
}

