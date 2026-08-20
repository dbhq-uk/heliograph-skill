# =============================================================================
#  containerappsjob/main.tf - run the heliograph agent as a scheduled Azure
#  Container Apps Job
# =============================================================================
#  The Terraform twin of containerappsjob/main.bicep. Same shape, same
#  traps, same result - see that file's header for the full reasoning,
#  especially the URL-travels-positionally workaround and the
#  scheduled-not-long-running trade-off.
# =============================================================================

terraform {
  required_version = ">= 1.5"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}

provider "azurerm" {
  features {}
}

variable "name" {
  description = "Name for the job."
  type        = string
  default     = "caj-heliograph"
}

variable "location" {
  description = "Location."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group to deploy into."
  type        = string
}

variable "vnetName" {
  description = "Existing VNet. Accepted for parameter parity with the other hosts, but NOT used directly here: the Container Apps Environment already owns the VNet integration."
  type        = string
  default     = ""
}

variable "subnetName" {
  description = "Existing subnet. See vnetName above: accepted for parity, not used."
  type        = string
  default     = ""
}

variable "containerAppsEnvironmentName" {
  description = "Existing Container Apps Environment, VNet-integrated on its own dedicated /27-or-larger subnet delegated to Microsoft.App/environments."
  type        = string
}

variable "repoUrl" {
  description = "The transport repo to clone, https:// or git@."
  type        = string
}

variable "gitToken" {
  description = "Token for an https:// transport repo. Leave empty for a public repo or an ssh:// remote."
  type        = string
  default     = ""
  sensitive   = true
}

variable "gitTokenUser" {
  description = "Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty."
  type        = string
  default     = ""
}

variable "image" {
  description = "Image to run."
  type        = string
  default     = "ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1"
}

variable "startArgs" {
  description = "Arguments for start.sh, and after --, for agent.sh. Defaults to [\"--\", \"--once\"]: a Job executes once per schedule tick and must exit."
  type        = list(string)
  default     = ["--", "--once"]
}

variable "cronExpression" {
  description = "Cron expression (UTC, standard 5-field) for how often a fresh execution starts."
  type        = string
  default     = "*/15 * * * *"
}

variable "replicaTimeoutSeconds" {
  description = "Seconds before an execution is killed for running too long."
  type        = number
  default     = 1800
}

variable "cpu" {
  type    = number
  default = 1.0
}

variable "memory" {
  type    = string
  default = "2Gi"
}

data "azurerm_container_app_environment" "this" {
  name                = var.containerAppsEnvironmentName
  resource_group_name = var.resource_group_name
}

resource "azurerm_container_app_job" "this" {
  name                         = var.name
  location                     = var.location
  resource_group_name          = var.resource_group_name
  container_app_environment_id = data.azurerm_container_app_environment.this.id

  replica_timeout_in_seconds = var.replicaTimeoutSeconds
  # 0, not the platform default: see main.bicep's matching comment - a
  # retry from a fresh container could re-poll and re-run the same request.
  replica_retry_limit = 0

  schedule_trigger_config {
    cron_expression          = var.cronExpression
    parallelism              = 1
    replica_completion_count = 1
  }

  dynamic "secret" {
    for_each = var.gitToken == "" ? [] : [1]
    content {
      name  = "git-token"
      value = var.gitToken
    }
  }

  template {
    container {
      name   = "agent"
      image  = var.image
      cpu    = var.cpu
      memory = var.memory

      # NO `command` set: unlike ACI's azurerm_container_group, which has
      # only `commands` (replacing the image's ENTRYPOINT outright),
      # azurerm_container_app_job's container block has separate `command`
      # and `args`, closer to Kubernetes. Leaving `command` unset keeps the
      # image's own ENTRYPOINT (entrypoint.sh) in force, and `args` below
      # becomes its argv.
      #
      # THE URL TRAVELS IN args, NOT AS A REPO_URL ENVIRONMENT VARIABLE.
      # The published image's entrypoint.sh refuses outright whenever
      # REPO_URL is set AND any positional argument is also given, and a
      # Job's whole point is passing --once - so REPO_URL and an argument
      # are unavoidable together here. Passing the URL positionally instead
      # avoids that refusal entirely and needs no new image tag. See
      # references/azure.md.
      args = concat([var.repoUrl], var.startArgs)

      dynamic "env" {
        for_each = var.gitTokenUser == "" ? [] : [1]
        content {
          name  = "GIT_TOKEN_USER"
          value = var.gitTokenUser
        }
      }

      dynamic "env" {
        for_each = var.gitToken == "" ? [] : [1]
        content {
          name        = "GIT_TOKEN"
          secret_name = "git-token"
        }
      }
    }
  }
}

output "job_name" {
  value = azurerm_container_app_job.this.name
}

output "trigger_command" {
  value = "az containerapp job start -g ${var.resource_group_name} -n ${azurerm_container_app_job.this.name}"
}

output "logs_query" {
  value = "az containerapp job logs show -g ${var.resource_group_name} -n ${azurerm_container_app_job.this.name} --container agent --follow"
}
