---
name: copilotstudio
description: Use this skill for Copilot Studio agent deployment and knowledge source management through Dataverse-backed REST operations.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - copilot-studio
  - dataverse
  - agents
  - powershell
  - automation
metadata:
  project: microsoft-cloud-api-skills
  domain: copilotstudio
---

# Copilot Studio Skill

## Agent Summary
Use this skill when an agent needs to read Copilot Studio bot metadata, publish or unpublish a bot, or manage knowledge sources directly in Dataverse. Supply a Dataverse context from `./skills/dataverse/Connect-DataverseApi.ps1`.

## When to Use
- Query Copilot Studio bot metadata from the `bots` entity set.
- Publish, unpublish, or update a Copilot Studio agent.
- Create, list, update, or delete Copilot Studio knowledge sources.

## Required Parameters
### `Get-CopilotAgentInfo.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Context` | `hashtable` | Yes | Dataverse context from `Connect-DataverseApi.ps1`. |
| `AgentId` | `string` | No | Retrieve one bot record. |
| `Select` | `string[]` | No | OData projection. |
| `Filter` | `string` | No | OData filter for list operations. |

### `Deploy-CopilotAgent.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `AgentId` | `string` | Yes | Copilot Studio bot identifier. |
| `Action` | `string` | Yes | `Publish`, `Unpublish`, or `Update`. |
| `Context` | `hashtable` | Yes | Dataverse context. |
| `AgentData` | `hashtable` | No | Required for update flows or PATCH-based publish/unpublish fallback. |
| `PublishActionName` | `string` | No | Dataverse bound action for publish. |
| `UnpublishActionName` | `string` | No | Dataverse bound action for unpublish. |

### `Manage-CopilotKnowledge.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Operation` | `string` | Yes | `List`, `Get`, `Create`, `Update`, or `Delete`. |
| `Context` | `hashtable` | Yes | Dataverse context. |
| `AgentId` | `string` | Conditional | Useful for scoped list operations and some relationship bindings. |
| `KnowledgeSourceId` | `string` | Conditional | Required for `Get`, `Update`, and `Delete`. |
| `KnowledgeSourceData` | `hashtable` | Conditional | Required for `Create` and `Update`. |
| `KnowledgeEntitySetName` | `string` | No | Defaults to `knowledgesources`. |
| `AgentFilterField` | `string` | No | Defaults to `_botid_value`. |

## Example Agent Prompts
- "List all Copilot Studio agents in this Dataverse environment."
- "Publish a Copilot Studio agent by bot ID."
- "Create a knowledge source and bind it to a Copilot Studio bot."

## Example Agent Workflow
```powershell
$ctx = ./skills/dataverse/Connect-DataverseApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud -EnvironmentUrl "https://contoso.crm.dynamics.com"

$agents = ./skills/copilotstudio/Get-CopilotAgentInfo.ps1 -Context $ctx -Select @('botid','name','statecode','statuscode')
```

## Security Caveats
- Copilot Studio is Dataverse-backed, so use Dataverse least-privilege roles and table permissions.
- Avoid client secrets in production; prefer managed identity or federated credentials.
- Bound action names and knowledge entity names can vary by environment, so verify them before writing automation that mutates data.

## Overview
Manage Copilot Studio agents and knowledge sources using the Dataverse Web API. The scripts operate directly on Dataverse `bots` and knowledge source entity sets via REST, with token and endpoint details supplied through `Connect-DataverseApi.ps1`.

## Authentication
- Dataverse Web API token (use the Dataverse environment URL as the token audience, passed into `Connect-DataverseApi.ps1` as `-EnvironmentUrl`)
- Accepts context from `Connect-DataverseApi.ps1` (or a compatible hashtable) with at least `Token` and `BaseUri`

## Endpoints
Uses Dataverse environment URL as base (for example, `https://contoso.crm.dynamics.com`).

## Skills
| File | Purpose |
| Deploy-CopilotAgent.ps1 | Publish, unpublish, or update a Copilot Studio agent by PATCHing the Dataverse `bots(<id>)` record, or by POSTing a bound action at `/bots(<id>)/Microsoft.Dynamics.CRM.<ActionName>` |
| Get-CopilotAgentInfo.ps1 | Retrieve Copilot Studio agent metadata from the Dataverse `bots` entity set, with optional OData `$select` and `$filter`, plus `@odata.nextLink` pagination |
| Manage-CopilotKnowledge.ps1 | Perform CRUD operations for Copilot Studio knowledge sources in Dataverse, including optional agent scoping for List via an OData filter on `AgentFilterField` |

## Patterns & Caveats
- Copilot Studio is Dataverse-backed (agents use the `bots` entity set)
- Publish/Unpublish can use bound actions or PATCH fallback
- Knowledge source entity names vary by environment (default: `knowledgesources`)
- Agent filter field varies by environment (default: `_botid_value`)
- OData-MaxVersion and OData-Version headers required

## Examples
3 practical examples: get agent info, publish agent, create knowledge source.

Get agent info

```powershell
$context = Connect-DataverseApi.ps1 -AuthenticationType ManagedIdentity -EnvironmentUrl "https://contoso.crm.dynamics.com" -Environment AzureCloud
$agent = Get-CopilotAgentInfo.ps1 -Context $context -AgentId $agentId -Select @('botid', 'name', 'statecode', 'statuscode')
```

Publish an agent (bound action)

```powershell
$context = Connect-DataverseApi.ps1 -AuthenticationType ClientCredentials -EnvironmentUrl "https://contoso.crm.dynamics.com" -Environment AzureCloud -TenantId $tenantId -ClientId $clientId -ClientSecret $clientSecret

Deploy-CopilotAgent.ps1 -Context $context -AgentId $agentId -Action Publish -PublishActionName 'PublishBot'
```

Create a knowledge source

```powershell
$context = Connect-DataverseApi.ps1 -AuthenticationType Federated -EnvironmentUrl "https://contoso.crm.dynamics.com" -Environment AzureCloud -TenantId $tenantId -ClientId $clientId -FederatedToken $oidcToken

Manage-CopilotKnowledge.ps1 -Context $context -Operation Create -KnowledgeSourceData @{
  name = 'Docs'
  'bot@odata.bind' = "/bots($agentId)"
}
```

## Prerequisites
- Required modules
  - PowerShell 7.2+ (all scripts use `#Requires -Version 7.2`)
  - The repo’s shared helpers, `skills/Common.psm1`, loaded by each script
  - `Connect-DataverseApi.ps1` (to build the required Dataverse REST context)
- Required permissions
  - Dataverse privileges to read and write the `bots` entity set for Copilot Studio agents
  - Dataverse privileges for the target knowledge source entity set (default: `knowledgesources`) and any relationships required by your environment
  - Permission to invoke bound actions when you use `-PublishActionName` or `-UnpublishActionName`

## Related Docs
- [Auth Patterns](../../docs/auth-patterns.md)
- [Token Chaining](../../docs/token-chaining.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)
