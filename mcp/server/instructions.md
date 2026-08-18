# Microsoft Cloud API Skills MCP Server

Use these tools to authenticate once and reuse the returned `ContextId` for later calls.

- Use `connect_graph_api` before `invoke_graph_request` or `get_intune_devices`.
- Use `connect_azure_api` before `invoke_azure_rest_method`.
- Use `connect_sentinel_api` before `get_sentinel_incidents` or `invoke_log_analytics_kql_query` when you want one call that prepares both Sentinel ARM and Log Analytics data-plane auth.
- Use `setup_authentication_context` when you want the repository's auto-detection logic for a specific resource audience.

Each tool returns structured PowerShell objects suitable for MCP clients.
