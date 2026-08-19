# =============================================================================
#  aci/main.tf - run the heliograph agent as a VNet-injected container group
# =============================================================================
#  The Terraform twin of aci/main.bicep. Same shape, same traps, same result -
#  see that file's header for the full reasoning; this one only notes where
#  Terraform's azurerm provider makes you say something differently.
#
#  BRING YOUR OWN NETWORK, as everywhere else in this PR: the VNet and subnet
#  already exist, and this creates the container group and nothing else. The
#  subnet must be delegated to Microsoft.ContainerInstance/containerGroups.
#
#  NO INBOUND, no file share, no storage account. Git is the persistence.
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
  description = "Name for the container group."
  type        = string
  default     = "aci-heliograph"
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
  description = "Existing VNet this container group joins."
  type        = string
}

variable "subnetName" {
  description = "Existing subnet, delegated to Microsoft.ContainerInstance/containerGroups."
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
  description = "Basic username for the token. GitHub wants x-access-token, GitLab oauth2, Azure DevOps empty. Getting this wrong looks like a prompt for a username, not an auth error."
  type        = string
  default     = ""
}

variable "image" {
  description = "Image to run."
  type        = string
  default     = "ghcr.io/dbhq-uk/heliograph-toolkit:1.0.0-rc1"
}

variable "startArgs" {
  description = "Arguments for start.sh, and after --, for agent.sh. The repo URL is NOT one of these: it travels as REPO_URL."
  type        = list(string)
  default     = []
}

variable "entrypoint" {
  description = "The image's entrypoint, needed only because ACI's `commands` field replaces it rather than appending to it, exactly as in the bicep version. Change it if you change the image."
  type        = string
  default     = "/usr/local/bin/entrypoint.sh"
}

variable "cpu" {
  type    = number
  default = 1
}

variable "memory" {
  type    = number
  default = 1
}

data "azurerm_subnet" "this" {
  name                 = var.subnetName
  virtual_network_name = var.vnetName
  resource_group_name  = var.resource_group_name
}

locals {
  # Same rule as the bicep version's `command`: empty startArgs leaves the
  # image's own ENTRYPOINT to run untouched; any startArgs must name the
  # entrypoint explicitly first, because azurerm_container_group's `commands`
  # is ACI's `command` field under the hood and REPLACES the ENTRYPOINT the
  # same way - there is still no separate `args` field to reach for instead.
  command = length(var.startArgs) == 0 ? [] : concat([var.entrypoint], var.startArgs)

  env_vars = merge(
    { REPO_URL = var.repoUrl },
    var.gitTokenUser == "" ? {} : { GIT_TOKEN_USER = var.gitTokenUser },
  )
  # GIT_TOKEN goes through secure_environment_variables below, not here, so it
  # never lands in `terraform show`/state's plain environment_variables map -
  # the azurerm_container_group equivalent of the bicep template's
  # secureValue. It is still readable by anyone who can read the container
  # group's own definition, same caveat as the bicep version.
  secure_env_vars = var.gitToken == "" ? {} : { GIT_TOKEN = var.gitToken }
}

resource "azurerm_container_group" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  # subnet_ids alone makes azurerm build an ipAddress object for the group
  # (a private IP is unavoidable once it joins a subnet). That object then
  # needs BOTH of these, in this order, or the API refuses it two different
  # ways:
  #   - no ports at all: "MissingIpAddressPorts: The ports in the
  #     'ipAddress' of container group ... cannot be empty."
  #   - ports with ip_address_type left unset (which defaults to "Public"):
  #     "InvalidIpAddressTypeForNetworkProfile: IP Address type can't be
  #     public when network profile is set."
  # The bicep version hits neither: it never mentions `ipAddress` at all,
  # and the API is happy to omit the object entirely for a VNet-injected
  # group with no ports. That is a difference in what the two tools
  # generate for the same intent, not a difference in what Azure allows.
  # The port below (see the container block) is declared, not bound: the
  # image never listens on it, and there is still no public IP - only the
  # ipAddress object's own validation needed satisfying.
  ip_address_type = "Private"
  subnet_ids      = [data.azurerm_subnet.this.id]

  # OnFailure, not Always, for the same reason as the bicep version: `stop:
  # yes` in agent/request is a clean exit and must stay stopped, not be
  # restarted by a policy that cannot tell a deliberate stop from a crash.
  restart_policy = "OnFailure"

  container {
    name   = "agent"
    image  = var.image
    cpu    = var.cpu
    memory = var.memory

    commands                     = local.command
    environment_variables        = local.env_vars
    secure_environment_variables = local.secure_env_vars

    # See the comment on subnet_ids above: this port is never bound by the
    # image and is not reachable from outside the group's own private IP.
    # It exists only because the provider needs at least one to build a
    # valid ipAddress object at all.
    ports {
      port     = 65000
      protocol = "TCP"
    }
  }
}

output "container_group_name" {
  value = azurerm_container_group.this.name
}

output "logs_command" {
  value = "az container logs -g ${var.resource_group_name} -n ${azurerm_container_group.this.name}"
}
