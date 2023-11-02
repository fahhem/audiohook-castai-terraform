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
  aws_cluster_vpc_id = local.eks_cluster.vpc_config[0].vpc_id

  castai_user_arn = castai_eks_user_arn.castai_user_arn.arn

  create_iam_resources_per_cluster = true
}

# Add the CastAI IAM role so CastAI nodes can join the cluster.
# We do this by reading the current maproles, then adding ours
locals {
  current_maproles = yamldecode(data.kubernetes_config_map.current_aws_auth.data["mapRoles"])
  updated_maproles = distinct(concat(local.current_maproles, [
    {
      rolearn  = module.castai-eks-role-iam.instance_profile_role_arn
      username = "system:node:{{EC2PrivateDNSName}}"
      groups   = ["system:bootstrappers", "system:nodes"]
    }
  ]))
}

data "kubernetes_config_map" "current_aws_auth" {
  metadata {
    name      = "aws-auth"
    namespace = "kube-system"
  }
}

resource "kubernetes_config_map_v1_data" "castai_aws_auth" {
  metadata {
    namespace = "kube-system"
    name      = "aws-auth"
  }

  data = {
    mapRoles = yamlencode(local.updated_maproles)
  }

  force = true
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
  node_templates = {
    default_by_castai = {
      name = "default-by-castai"
      configuration_id = module.castai-eks-cluster.castai_node_configurations["default"]
      is_default   = true
      should_taint = false

      constraints = {
        on_demand          = true
        spot               = true
        use_spot_fallbacks = true

        enable_spot_diversity                       = false
        spot_diversity_price_increase_limit_percent = 20

        spot_interruption_predictions_enabled = true
        spot_interruption_predictions_type = "aws-rebalance-recommendations"
      }
    }
    Application = {
      configuration_id = module.castai-eks-cluster.castai_node_configurations["default"]
      should_taint     = true

      custom_labels = {
        "audiohook.com/application" = "bidder"
      }

      custom_taints = [
        {
          key = "audiohook.com/application"
          value = "bidder"
          effect = "NoSchedule"
        },
      ]

      constraints = {
        fallback_restore_rate_seconds = 1800
        spot                          = true
        use_spot_fallbacks            = true
        spot_interruption_predictions_enabled = true
        spot_interruption_predictions_type = "interruption-predictions"
      }
    }
    Dedicated = {
      configuration_id = module.castai-eks-cluster.castai_node_configurations["default"]
      should_taint     = true

      custom_labels = {
        "zeet.co/dedicated" = "guaranteed"
      }

      custom_taints = [
        {
          key = "zeet.co/dedicated"
          value = "guaranteed"
          effect = "NoSchedule"
        },
      ]

      constraints = {
        fallback_restore_rate_seconds = 1800
        spot                          = true
        use_spot_fallbacks            = true
        spot_interruption_predictions_enabled = true
        spot_interruption_predictions_type = "interruption-predictions"
        max_cpu                       = 8
      }
    }
    Dedicated-Dedicated = {
      configuration_id = module.castai-eks-cluster.castai_node_configurations["default"]
      should_taint     = true

      custom_labels = {
        "zeet.co/dedicated" = "dedicated"
      }

      custom_taints = [
        {
          key = "zeet.co/dedicated"
          value = "dedicated"
          effect = "NoSchedule"
        },
      ]

      constraints = {
        fallback_restore_rate_seconds = 1800
        spot                          = true
        use_spot_fallbacks            = true
        spot_interruption_predictions_enabled = true
        spot_interruption_predictions_type = "interruption-predictions"
      }
    }
    Guaranteed = {
      configuration_id = module.castai-eks-cluster.castai_node_configurations["default"]
      should_taint     = true

      custom_labels = {
        "zeet.co/dedicated" = "system"
      }

      custom_taints = []

      constraints = {
        spot                          = false
        spot_interruption_predictions_enabled = true
      }
    }
  }

  # Configure Autoscaler policies as per API specification https://api.cast.ai/v1/spec/#/PoliciesAPI/PoliciesAPIUpsertClusterPolicies.
  # Here:
  #  - unschedulablePods - Unscheduled pods policy
  #  - nodeDownscaler    - Node deletion policy
  autoscaler_policies_json = <<-EOT
    {
      "clusterLimits": {
        "cpu": {
          "maxCores": 20,
          "minCores": 1
        },
        "enabled": true
      },
      "enabled": false,
      "isScopedMode": false,
      "nodeDownscaler": {
        "emptyNodes": {
          "delaySeconds": 0,
          "enabled": false
        },
        "enabled": true,
        "evictor": {
          "aggressiveMode": false,
          "allowed": true,
          "cycleInterval": "5m10s",
          "dryRun": false,
          "enabled": false,
          "nodeGracePeriodMinutes": 10,
          "scopedMode": false,
          "status": "Unknown"
        }
      },
      "spotInstances": {
        "clouds": [
          "aws"
        ],
        "enabled": false,
        "maxReclaimRate": 0,
        "spotBackups": {
          "enabled": false,
          "spotBackupRestoreRateSeconds": 1800
        },
        "spotDiversityEnabled": false,
        "spotDiversityPriceIncreaseLimitPercent": 20,
        "spotInterruptionPredictions": {
          "enabled": false,
          "type": "AWSRebalanceRecommendations"
        }
      },
      "unschedulablePods": {
        "customInstancesEnabled": true,
        "diskGibToCpuRatio": 5,
        "enabled": false,
        "headroom": {
          "cpuPercentage": 10,
          "enabled": true,
          "memoryPercentage": 10
        },
        "headroomSpot": {
          "cpuPercentage": 10,
          "enabled": true,
          "memoryPercentage": 10
        },
        "nodeConstraints": {
          "enabled": false,
          "maxCpuCores": 32,
          "maxRamMib": 262144,
          "minCpuCores": 2,
          "minRamMib": 2048
        }
      }
    }
  EOT

  # depends_on helps Terraform with creating proper dependencies graph in case of resource creation and in this case destroy.
  # module "castai-eks-cluster" has to be destroyed before module "castai-eks-role-iam".
  depends_on = [module.castai-eks-role-iam]
}

# resource "castai_rebalancing_schedule" "spots" {
#   name = "rebalance spots at every 30th minute ${var.cluster_name}"
#   schedule {
#     cron = "*/30 * * * *"
#   }
#   trigger_conditions {
#     savings_percentage = 20
#   }
#   launch_configuration {
#     # only consider instances older than 5 minutes
#     node_ttl_seconds         = 300
#     num_targeted_nodes       = 3
#     rebalancing_min_nodes    = 2
#     keep_drain_timeout_nodes = false
#     selector = jsonencode({
#       nodeSelectorTerms = [{
#         matchExpressions = [
#           {
#             key      = "scheduling.cast.ai/spot"
#             operator = "Exists"
#           }
#         ]
#       }]
#     })
#     execution_conditions {
#       enabled                     = true
#       achieved_savings_percentage = 10
#     }
#   }
# }
# 
# resource "castai_rebalancing_job" "spots" {
#   cluster_id              = castai_eks_clusterid.cluster_id.id
#   rebalancing_schedule_id = castai_rebalancing_schedule.spots.id
#   enabled                 = true
# }
