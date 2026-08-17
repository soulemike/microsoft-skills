# Copilot Studio Skill

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
- [Auth Patterns](../docs/auth-patterns.md)
- [Token Chaining](../docs/token-chaining.md)
- [Environment Endpoints](../docs/environment-endpoints.md)
