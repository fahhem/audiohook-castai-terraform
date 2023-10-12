# Configure Data sources and providers required for CAST AI connection.
data "aws_caller_identity" "current" {}

resource "castai_eks_user_arn" "castai_user_arn" {
  cluster_id = castai_eks_clusterid.cluster_id.id
}

# Create AWS IAM policies and a user to connect to CAST AI.
module "castai-eks-role-iam" {
  source = "castai/eks-role-iam/castai"

  aws_account_id     = data.aws_caller_identity.current.account_id
  aws_cluster_region = var.cluster_region
  aws_cluster_name   = var.cluster_name
  aws_cluster_vpc_id = local.eks_cluster.vpc_config[0].cluster_security_group_id

  castai_user_arn = castai_eks_user_arn.castai_user_arn.arn

  create_iam_resources_per_cluster = true
}

# Configure EKS cluster connection using CAST AI eks-cluster module.
resource "castai_eks_clusterid" "cluster_id" {
  account_id   = data.aws_caller_identity.current.account_id
  region       = var.cluster_region
  cluster_name = var.cluster_name
}

module "castai-eks-cluster" {
  source = "castai/eks-cluster/castai"

  api_url                = var.castai_api_url
  castai_api_token       = var.castai_api_token
  wait_for_cluster_ready = true

  aws_account_id     = data.aws_caller_identity.current.account_id
  aws_cluster_region = var.cluster_region
  aws_cluster_name   = var.cluster_name

  aws_assume_role_arn        = module.castai-eks-role-iam.role_arn
  delete_nodes_on_disconnect = var.delete_nodes_on_disconnect

  default_node_configuration = module.castai-eks-cluster.castai_node_configurations["default"]

  node_configurations = {
    default = {
      subnets = data.aws_subnets.existing_cluster.ids
      tags    = var.tags
      security_groups = concat([
        local.eks_cluster.vpc_config[0].cluster_security_group_id,
      ], tolist(local.eks_cluster.vpc_config[0].security_group_ids))
      instance_profile_arn = module.castai-eks-role-iam.instance_profile_arn
    }
  }

  # Configure Autoscaler policies as per API specification https://api.cast.ai/v1/spec/#/PoliciesAPI/PoliciesAPIUpsertClusterPolicies.
  # Here:
  #  - unschedulablePods - Unscheduled pods policy
  #  - nodeDownscaler    - Node deletion policy
  autoscaler_policies_json = "{}"

  # depends_on helps Terraform with creating proper dependencies graph in case of resource creation and in this case destroy.
  # module "castai-eks-cluster" has to be destroyed before module "castai-eks-role-iam".
  depends_on = [module.castai-eks-role-iam]
}

resource "castai_rebalancing_schedule" "spots" {
  name = "rebalance spots at every 30th minute"
  schedule {
    cron = "*/30 * * * *"
  }
  trigger_conditions {
    savings_percentage = 20
  }
  launch_configuration {
    # only consider instances older than 5 minutes
    node_ttl_seconds         = 300
    num_targeted_nodes       = 3
    rebalancing_min_nodes    = 2
    keep_drain_timeout_nodes = false
    selector = jsonencode({
      nodeSelectorTerms = [{
        matchExpressions = [
          {
            key      = "scheduling.cast.ai/spot"
            operator = "Exists"
          }
        ]
      }]
    })
    execution_conditions {
      enabled                     = true
      achieved_savings_percentage = 10
    }
  }
}

resource "castai_rebalancing_job" "spots" {
  cluster_id              = castai_eks_clusterid.cluster_id.id
  rebalancing_schedule_id = castai_rebalancing_schedule.spots.id
  enabled                 = true
}
