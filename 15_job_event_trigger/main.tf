terraform {
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

resource "azurerm_resource_group" "rg" {
  name     = "rg-aca-job-event-trigger"
  location = "uksouth"
}

resource "azurerm_container_app_environment" "aca_environment" {
  name                       = "aca-environment"
  location                   = azurerm_resource_group.rg.location
  resource_group_name        = azurerm_resource_group.rg.name
}

resource "azurerm_servicebus_namespace" "service-bus" {
  name                          = "service-bus-namespace-1222"
  location                      = azurerm_resource_group.rg.location
  resource_group_name           = azurerm_resource_group.rg.name
  sku                           = "Standard"
  capacity                      = 0
  public_network_access_enabled = true
}

resource "azurerm_servicebus_queue" "queue-messages" {
  name                = "queue-messages"
  namespace_id        = azurerm_servicebus_namespace.service-bus.id
  partitioning_enabled = false
  lock_duration       = "PT5M" # amount of time that the message is locked for other receivers, 1 min, max 5 min
  max_delivery_count  = 1
}

# assign rights for the ACA Job Managed identity to access Service Bus Queue
# Give the managed identity the RBAC role to receive messages from the queue
resource "azurerm_role_assignment" "role-receiver-queue-identity" {
  scope                = azurerm_servicebus_queue.queue-messages.id
  role_definition_name = "Azure Service Bus Data Receiver"
  principal_id         = azurerm_container_app_job.job.identity[0].principal_id
}

# Give the managed identity the RBAC role to send messages to the queue
resource "azurerm_role_assignment" "role-sender-queue-identity" {
  scope                = azurerm_servicebus_queue.queue-messages.id
  role_definition_name = "Azure Service Bus Data Sender"
  principal_id         = azurerm_container_app_job.job.identity[0].principal_id
}

# Azurerm v5, fully supports ACA jobs and managed identity auth for Keda.
resource "azurerm_container_app_job" "job" {
  name                         = "aca-job-keda"
  location                     = azurerm_resource_group.rg.location
  resource_group_name          = azurerm_resource_group.rg.name
  container_app_environment_id = azurerm_container_app_environment.aca_environment.id
  replica_timeout_in_seconds   = 600
  replica_retry_limit          = 1

  identity {
    type = "SystemAssigned"
  }

  event_trigger_config {
    replica_completion_count = 1
    parallelism              = 1
    
    scale {
      min_executions = 0
      max_executions = 1
      
      rules {
        name             = "azure-servicebus-queue-rule"
        custom_rule_type = "azure-servicebus"
        
        # While not documented in Terraform provider docs, it is valid.
        identity_id = "System"
        
        metadata = {
          queueName    = azurerm_servicebus_queue.queue-messages.name
          namespace    = azurerm_servicebus_namespace.service-bus.name
          messageCount = "1"
        }
      }
    }
  }

  template {
    container {
      image  = "mcr.microsoft.com/k8se/quickstart-jobs:latest"
      name   = "aca-job-demo"
      cpu    = 0.5
      memory = "1Gi"
    }
  }
}

