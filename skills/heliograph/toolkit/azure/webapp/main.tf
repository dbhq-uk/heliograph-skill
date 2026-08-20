# =============================================================================
#  webapp/main.tf - run the heliograph agent as a Web App for Containers
# =============================================================================
#  The Terraform twin of webapp/main.bicep. Same shape, same traps, same
#  result - see that file's header for the full reasoning. This creates one
#  azurerm_linux_web_app and nothing else: the VNet, subnet and App Service
#  Plan already exist in the estate.
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
  description = "Name for the web app (must be globally unique - becomes <name>.azurewebsites.net)."
  type        = string
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
  description = "Existing VNet this app integrates with."
  type        = string
}

variable "subnetName" {
  description = "Existing subnet, delegated to Microsoft.Web/serverFarms."
  type        = string
}

variable "planName" {
  description = "Existing Linux App Service Plan, Basic tier or above (Free/Shared do not support VNet integration or Always On)."
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
  description = "Arguments for start.sh, and after --, for agent.sh. The repo URL is NOT one of these: it travels as REPO_URL. Space-joined into the Startup Command."
  type        = list(string)
  default     = []
}

variable "cpu" {
  description = "Accepted for parameter parity with the other hosts in this PR, but NOT actionable here: sizing comes entirely from the App Service Plan's SKU (planName above)."
  type        = number
  default     = 1
}

variable "memory" {
  description = "See cpu above: not actionable for this host, kept only for parameter parity."
  type        = number
  default     = 1
}

data "azurerm_service_plan" "this" {
  name                = var.planName
  resource_group_name = var.resource_group_name
}

data "azurerm_subnet" "this" {
  name                 = var.subnetName
  virtual_network_name = var.vnetName
  resource_group_name  = var.resource_group_name
}

resource "azurerm_linux_web_app" "this" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = data.azurerm_service_plan.this.id

  virtual_network_subnet_id = data.azurerm_subnet.this.id

  site_config {
    # Regional VNet Integration is outbound-only by default: it routes only
    # traffic bound for addresses inside the VNet through the integration.
    # Everything else - including the git host - would otherwise take the
    # platform's own public egress, defeating the point of handing this
    # template a subnet at all. vnet_route_all_enabled sends everything
    # through it instead, matching the bicep version's vnetRouteAllEnabled.
    vnet_route_all_enabled = true
    # Keeps the container running with no inbound HTTP traffic. Web Apps
    # idle out and unload the container after ~20 minutes without a request
    # when this is off - fatal for a loop whose whole job is to sit there
    # polling git with nothing to serve. Needs Basic tier or above.
    always_on = true

    application_stack {
      # The FULL reference, registry host included (var.image is already
      # "ghcr.io/dbhq-uk/..."). docker_registry_url is deliberately NOT set
      # alongside it: that field is for a registry that needs credentials
      # attached separately (ACR, a private Docker Hub repo), and setting it
      # here as well double-prefixes what azurerm builds - linuxFxVersion
      # came out as "DOCKER|ghcr.io/ghcr.io/dbhq-uk/...", a registry ghcr.io
      # does not have, and the app never started. Found by deploying this
      # exact shape - see references/azure.md. For a public registry the
      # image name alone is enough.
      docker_image_name = var.image
    }

    # The image's ENTRYPOINT is never touched here - App Service's Startup
    # Command is appended as arguments to whatever the image already
    # declares, unlike ACI's `command`/`commands`, which replaces the
    # ENTRYPOINT outright. An empty startArgs leaves this empty and the
    # image's own ENTRYPOINT runs with no arguments - see main.bicep's
    # matching comment, confirmed by hand and recorded in
    # references/azure.md.
    app_command_line = join(" ", var.startArgs)
  }

  app_settings = merge(
    {
      REPO_URL = var.repoUrl
      # Turns off the persistent Azure Files /home mount every Linux
      # container Web App gets by default, so the checkout stays exactly as
      # transient as it is on every other host in this PR: git is the
      # persistence, not the platform.
      WEBSITES_ENABLE_APP_SERVICE_STORAGE = "false"
    },
    var.gitTokenUser == "" ? {} : { GIT_TOKEN_USER = var.gitTokenUser },
    # App settings have no separate "secure" field the way ACI's
    # secure_environment_variables does - this still keeps the token out of
    # the .tf files and out of a plan's diff-free re-apply, but anyone who
    # can read this app's own configuration
    # (`az webapp config appsettings list`) can read it back in plain text.
    # Same caveat as every other host's environment-variable credential.
    var.gitToken == "" ? {} : { GIT_TOKEN = var.gitToken },
  )
}

output "site_name" {
  value = azurerm_linux_web_app.this.name
}

output "logs_command" {
  value = "az webapp log tail -g ${var.resource_group_name} -n ${azurerm_linux_web_app.this.name}"
}
