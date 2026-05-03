output "servicebus_namespace_name" {
  description = "Name of the Service Bus namespace."
  value       = azurerm_servicebus_namespace.main.name
}

output "producer_connection_string" {
  description = "Connection string for the Producer (Send rights on the orders queue). Use with SERVICE_BUS_PRODUCER_CONNECTION_STRING."
  value       = azurerm_servicebus_queue_authorization_rule.producer_send.primary_connection_string
  sensitive   = true
}

output "consumer_connection_string" {
  description = "Connection string for the Consumer and DLQ Handler (Listen rights on the orders queue). Use with SERVICE_BUS_CONSUMER_CONNECTION_STRING."
  value       = azurerm_servicebus_queue_authorization_rule.consumer_listen.primary_connection_string
  sensitive   = true
}

output "orders_queue_name" {
  description = "Name of the primary orders queue."
  value       = azurerm_servicebus_queue.orders.name
}

output "dlq_entity_path" {
  description = "Full entity path of the dead-letter sub-queue."
  value       = "${azurerm_servicebus_queue.orders.name}/$DeadLetterQueue"
}

output "resource_group_name" {
  description = "Resource group containing all provisioned resources."
  value       = azurerm_resource_group.main.name
}
