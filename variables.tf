# EKS module variables.
variable "cluster_name" {
  type        = string
  description = "EKS cluster name in AWS account."
}

variable "cluster_region" {
  type = string
  description = "AWS Region in which EKS cluster and supporting resources will be created."
}

variable "cluster_version" {
  type        = string
  description = "EKS cluster version."
  default     = "1.24"
}

variable "cluster_security_group_id" {
  type = string
  description = "Cluster security group ID. Group name should be 'eks-cluster-sg-zeet-{cluster_name}-{timestamp}'"
}

variable "node_security_group_id" {
  type = string
  description = "Cluster node security group ID. Group name should be 'zeet-{cluster_name}-node'"
}

variable "cluster_vpc_id" {
  type        = string
  description = "EKS cluster VPC ID"
}

variable "castai_api_url" {
  type = string
  description = "URL of alternative CAST AI API to be used during development or testing"
  default     = "https://api.cast.ai"
}

# Variables required for connecting EKS cluster to CAST AI.
variable "castai_api_token" {
  type = string
  description = "CAST AI API token created in console.cast.ai API Access keys section"
}

variable "delete_nodes_on_disconnect" {
  type        = bool
  description = "Optional parameter, if set to true - CAST AI provisioned nodes will be deleted from cloud on cluster disconnection. For production use it is recommended to set it to false."
  default     = true
}

variable "tags" {
  type        = map(any)
  description = "Optional tags for new cluster nodes. This parameter applies only to new nodes - tags for old nodes are not reconciled."
  default     = {}
}


