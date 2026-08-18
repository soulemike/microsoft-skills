# Microsoft Cloud API Skills MCP Server

This directory contains a minimal stdio MCP server for the Microsoft Cloud API Skills project. It uses the PowerShell-native [`pwsh.mcp.sdk`](https://github.com/KevinMarquette/pwsh.mcp.sdk) so the server stays PowerShell-only and can expose typed `.ps1` tools without adding Node.js or Python.

## What the server exposes

The server publishes these MCP tools:

- `setup_authentication_context`
- `connect_graph_api`
- `connect_azure_api`
- `connect_sentinel_api`
- `connect_intune_api`
- `invoke_graph_request`
- `invoke_azure_rest_method`
- `invoke_log_analytics_kql_query`
- `get_sentinel_incidents`
- `get_intune_devices`

The wrappers call the existing repository scripts under `prerequisites/` and `skills/` without modifying them.

## Session state and auth context reuse

Every `connect_*` tool and `setup_authentication_context` stores the returned auth context in the running MCP server process and returns a `ContextId`.

Use either of these patterns in later calls:

1. Pass `ContextId` directly.
2. Pass the returned `AuthContext` object.

Example flow:

1. Call `connect_graph_api`
2. Receive a result like:

```json
{
  "ContextId": "graph-1",
  "ContextType": "graph",
  "AuthContext": {
    "Token": "...",
    "BaseUri": "https://graph.microsoft.com/v1.0",
    "Environment": "AzureCloud"
  }
}
```

3. Call `invoke_graph_request` with either:

```json
{
  "ContextId": "graph-1",
  "Uri": "/users",
  "Paginate": true
}
```

or:

```json
{
  "AuthContext": {
    "Token": "...",
    "BaseUri": "https://graph.microsoft.com/v1.0",
    "Environment": "AzureCloud"
  },
  "Uri": "/users"
}
```

`connect_sentinel_api` returns a bundled session containing both:

- `SentinelArmContext` for Sentinel ARM operations such as `get_sentinel_incidents`
- `LogAnalyticsContext` for `invoke_log_analytics_kql_query`

## Installation

### 1. Install the SDK locally under `mcp/.sdk/`

From the repository root:

```powershell
./mcp/Install-McpSdk.ps1
```

That downloads `pwsh.mcp.sdk` from GitHub and extracts it into:

```text
mcp/.sdk/pwsh.mcp.sdk/
```

If you already have a clone elsewhere, set `MCP_SDK_ROOT` instead of installing locally.

### 2. Start the MCP server manually

```powershell
./mcp/Start-MicrosoftCloudApiSkillsMcp.ps1
```

The server runs over stdio by default, which is the MCP standard transport for Claude Code, Cursor, and similar clients.

## Client configuration

### Cursor / VS Code style `mcp.json`

The repository includes `mcp/mcp-server.json` as a ready-made example. Most clients also accept an inline config like this:

```json
{
  "mcpServers": {
    "microsoft-cloud-api-skills": {
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-NoLogo",
        "-File",
        "/absolute/path/to/microsoftSkills/mcp/Start-MicrosoftCloudApiSkillsMcp.ps1"
      ],
      "env": {
        "MCP_SDK_ROOT": "/absolute/path/to/microsoftSkills/mcp/.sdk/pwsh.mcp.sdk"
      }
    }
  }
}
```

### Claude Code example

Use the same stdio command and arguments in your Claude Code MCP configuration:

```json
{
  "mcpServers": {
    "microsoft-cloud-api-skills": {
      "command": "pwsh",
      "args": [
        "-NoProfile",
        "-NoLogo",
        "-File",
        "/absolute/path/to/microsoftSkills/mcp/Start-MicrosoftCloudApiSkillsMcp.ps1"
      ],
      "env": {
        "MCP_SDK_ROOT": "/absolute/path/to/microsoftSkills/mcp/.sdk/pwsh.mcp.sdk"
      }
    }
  }
}
```

## Parameter notes

- Tool names intentionally follow snake_case to match common MCP naming conventions.
- Parameters mirror the existing PowerShell skill parameter sets as closely as possible.
- `ClientSecret` is accepted as a plain string at the MCP boundary and converted to `SecureString` before calling the underlying project scripts.
- Existing skill scripts are left unchanged.

## File layout

```text
mcp/
├── Install-McpSdk.ps1
├── Start-MicrosoftCloudApiSkillsMcp.ps1
├── README.md
├── mcp-server.json
└── server/
    ├── MicrosoftCloudApiSkills.Mcp.psm1
    ├── instructions.md
    └── tools/
```
