# =============================================================================
#  function/main.tf - run the heliograph agent as an Azure Function
# =============================================================================
#  The fifth host, and the only one that needs no long-lived compute, no VM
#  quota and no inbound path. A timer fires, the agent answers at most one
#  request, and the invocation ends.
#
#  WHEN TO REACH FOR THIS. When the estate will not give you anywhere to keep a
#  process. It was written after three container hosts were refused in one
#  subscription: App Service quota was zero on every SKU that allocates a VM,
#  and a VNet-injected Container Apps environment could not provision because
#  the platform itself needs outbound and the subnet had none. Flex Consumption
#  needed neither.
#
#  IT USES THE PIGEONHOLE, NOT GIT, AND NOT BY PREFERENCE. There is no git
#  binary in the Functions Python image. That turns out to be the feature
#  rather than the limitation: blob storage behind a private endpoint needs no
#  egress at all, so this host works in a subnet with no route off it.
#
#  BRING YOUR OWN NETWORK. The VNet, the subnet and the storage account already
#  exist. This creates the plan, the app and nothing else.
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
  description = "Name for the function app."
  type        = string
  default     = "heliograph-agent"
}

variable "location" {
  description = "Azure region."
  type        = string
}

variable "resource_group_name" {
  description = "Existing resource group. Not created here."
  type        = string
}

# FLEX CONSUMPTION, AND CHECK THIS BEFORE ANYTHING ELSE. Quota for App Service
# SKUs is per-SKU and can be zero without the region saying so - `az appservice
# list-locations` describes the region, not the subscription. The read-only way
# to measure it is ARM preflight: `az deployment group validate` against a
# Microsoft.Web/serverfarms template returns the quota error without creating
# anything. On the estate this was written for, nine SKUs returned zero and FC1
# was the only one that validated.
variable "sku_name" {
  description = "App Service plan SKU. FC1 is Flex Consumption."
  type        = string
  default     = "FC1"
}

variable "storage_account_name" {
  description = "Existing storage account. Holds the deployment package, and can also hold the pigeonhole drop."
  type        = string
}

variable "storage_account_access_key" {
  description = "Key for the deployment container. Never committed."
  type        = string
  sensitive   = true
}

# THE SUBNET IS WHAT PUTS THE AGENT INSIDE THE ESTATE. Without it the app runs
# on the platform's network and can reach nothing private - which is usually
# the entire reason for deploying a runner at all. It must be delegated to
# Microsoft.App/environments.
variable "subnet_id" {
  description = "Existing subnet for VNet integration, delegated to Microsoft.App/environments. Empty means no integration."
  type        = string
  default     = ""
}

# TRUE PUTS EVERY OUTBOUND CONNECTION THROUGH THE SUBNET, including the ones
# the platform makes. That is what you want when the drop is on a private
# endpoint and there is no egress; it is what you do NOT want if the agent
# needs the internet and the subnet has no route to it. This is the setting
# that decides whether git could ever work here.
variable "vnet_route_all_enabled" {
  description = "Route all outbound traffic through the integration subnet."
  type        = bool
  default     = true
}

variable "pigeonhole_account" {
  description = "Storage account holding the drop - requests, logs, status and agent containers."
  type        = string
}

variable "pigeonhole_sas" {
  description = "SAS for the drop. Never committed; keep the expiry short."
  type        = string
  sensitive   = true
}

# THE LANE IS THE BINDING. Two runners must never answer one request: a
# heliograph log's whole value is that it says what ONE machine saw, and two
# logs seconds apart from two hosts is a failure that looks like success.
variable "pigeonhole_lane" {
  description = "Which request this runner answers - requests/<lane>.txt. No two runners may share a lane."
  type        = string
  default     = "default"
}

# EVERY SIX HOURS, NOT EVERY MINUTE. A timer this slow looks wrong until you
# remember what it costs to be wrong in the other direction: the runner is
# unattended, and a fast timer on a misconfigured lane is a step running every
# minute with nobody watching. Tighten it while an investigation is live.
variable "schedule" {
  description = "NCRONTAB expression for the timer. Six fields, seconds first."
  type        = string
  default     = "0 0 */6 * * *"
}

variable "allow_actions" {
  description = "Whether the agent may run a state-changing step. Off by default, and the request must still say CONFIRM=yes."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to what this creates."
  type        = map(string)
  default     = {}
}

resource "azurerm_service_plan" "agent" {
  name                = "${var.name}-plan"
  location            = var.location
  resource_group_name = var.resource_group_name
  os_type             = "Linux"
  sku_name            = var.sku_name

  tags = var.tags
}

resource "azurerm_function_app_flex_consumption" "agent" {
  name                = var.name
  location            = var.location
  resource_group_name = var.resource_group_name
  service_plan_id     = azurerm_service_plan.agent.id

  storage_container_type      = "blobContainer"
  storage_container_endpoint  = "https://${var.storage_account_name}.blob.core.windows.net/${var.name}-deployments"
  storage_authentication_type = "StorageAccountConnectionString"
  storage_access_key          = var.storage_account_access_key

  runtime_name    = "python"
  runtime_version = "3.12"

  # NOTHING CONNECTS TO THE AGENT. It makes outbound connections only, so the
  # public endpoint is closed rather than left open and unused.
  public_network_access_enabled = false

  virtual_network_subnet_id = var.subnet_id == "" ? null : var.subnet_id

  site_config {
    vnet_route_all_enabled = var.subnet_id == "" ? false : var.vnet_route_all_enabled
  }

  app_settings = {
    PIGEONHOLE_ACCOUNT  = var.pigeonhole_account
    PIGEONHOLE_SAS      = var.pigeonhole_sas
    PIGEONHOLE_LANE     = var.pigeonhole_lane
    HELIOGRAPH_SCHEDULE = var.schedule

    # The two that make a loop behave like an invocation. function_app.py sets
    # them too; they are here so that what the runner does is visible in the
    # app's own configuration rather than only in its code.
    PIGEONHOLE_RESUME = "1"
    PIGEONHOLE_ONCE   = "1"

    HELIOGRAPH_ALLOW_ACTIONS = var.allow_actions ? "1" : "0"
  }

  tags = var.tags
}

output "name" {
  description = "The function app."
  value       = azurerm_function_app_flex_consumption.agent.name
}

# A FUNCTION THAT NEVER FIRES LOOKS IDENTICAL TO ONE WITH NOTHING TO DO. This
# is how to tell them apart.
output "check_logs" {
  description = "Watch the agent decide whether to run."
  value       = "az webapp log tail -g ${var.resource_group_name} -n ${var.name}"
}

output "lane" {
  description = "The request this runner answers. No other runner may be given it."
  value       = "requests/${var.pigeonhole_lane}.txt"
}
