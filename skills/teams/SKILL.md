---
name: teams
description: Use this skill for Microsoft Teams channel and membership retrieval through Microsoft Graph with automatic pagination.
version: 1.0.0
license: MIT
author: Microsoft
tags:
  - microsoft
  - teams
  - graph
  - collaboration
  - powershell
  - automation
metadata:
  project: microsoft-cloud-api-skills
  domain: teams
---

# Microsoft Teams Skill

## Agent Summary
Use this skill for Teams channel and membership reads that are exposed through Microsoft Graph. Authenticate with `./skills/graph/Connect-GraphApi.ps1`, then use the Teams wrappers for team channels, team members, or channel members.

## When to Use
- List channels for a team.
- Retrieve one channel by ID.
- List team members or private/shared channel members.

## Required Parameters
### `Get-TeamsChannel.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `TeamId` | `string` | Yes | Microsoft Teams team identifier. |
| `AuthContext` | `hashtable` | Yes | Graph auth context from `Connect-GraphApi.ps1`. |
| `ChannelId` | `string` | No | Retrieve a single channel instead of listing. |

### `Get-TeamsMember.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `TeamId` | `string` | Yes | Microsoft Teams team identifier. |
| `AuthContext` | `hashtable` | Yes | Graph auth context from `Connect-GraphApi.ps1`. |
| `ChannelId` | `string` | No | When present, retrieves channel-specific members. |

### `Invoke-TeamsGraphRequest.ps1`
| Parameter | Type | Required | Notes |
|---|---|---|---|
| `Uri` | `string` | Yes | Teams-relative path or absolute Graph nextLink URL. |
| `AuthContext` | `hashtable` | Yes | Graph auth context. |
| `Method` | `string` | No | Defaults to `GET`. |
| `Body` | `object` | No | Request payload for writes. |

## Example Agent Prompts
- "List all channels in this Microsoft Team."
- "Get all members of a private Teams channel."
- "Call the Teams Graph endpoint directly for a team membership query."

## Example Agent Workflow
```powershell
$ctx = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud

$channels = ./skills/teams/Get-TeamsChannel.ps1 -TeamId $teamId -AuthContext $ctx
```

## Security Caveats
- Teams APIs are Graph APIs, so limit Graph application permissions to the smallest set possible.
- Some membership operations are valid only for private or shared channels; standard channels inherit team membership.
- Avoid client secret auth in production when managed identity or federated credentials are possible.

## Overview
This skill automates Microsoft Teams channel and membership retrieval using Microsoft Graph. It wraps Teams-specific Graph paths and automatically follows Graph pagination.

## Authentication
- Graph v1.0 token
- App-only with application permissions
- Group.ReadWrite.All often required

## Endpoints
Uses Graph endpoint from environment (see Environment Endpoints doc).

## Skills
| File | Purpose |
|------|---------|
| Get-TeamsChannel.ps1 | Gets channel details for a team, or lists all channels for a team. |
| Get-TeamsMember.ps1 | Gets team members, or channel members for a specific channel. |
| Invoke-TeamsGraphRequest.ps1 | Invokes Teams Graph requests (relative Teams paths) and follows @odata.nextLink pagination. |

## Toolchain
| Service | Tool | Best For | Graph Version | Limitations |
|---------|------|----------|---------------|-------------|
| **Teams** | **Microsoft.Graph** SDK (`Get-MgTeam`, `Get-MgTeamChannel`) | Team/channel lifecycle, messages, tabs, apps | `v1.0` | Large module footprint; some operations require Group.ReadWrite.All |
| **Teams** | **Raw REST** (`Invoke-MgGraphRequest`) | Direct control over Teams endpoints | `v1.0` / `beta` | Caller must handle pagination and throttling |
| **Teams** | **PnP CLI** (`m365 teams`) | Cross-platform Teams admin scripting | `v1.0` | Community-driven; no Microsoft SLA |

## Patterns & Caveats
- Teams operations are Graph operations
- beta only for preview features
- Pagination via @odata.nextLink

## Examples
1. List all channels in a team (GET `/teams/{team-id}/channels`):

```powershell
$authContext = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
./skills/teams/Get-TeamsChannel.ps1 -TeamId $teamId -AuthContext $authContext
```

2. Get a specific channel within a team (GET `/teams/{team-id}/channels/{channel-id}`):

```powershell
$authContext = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
./skills/teams/Get-TeamsChannel.ps1 -TeamId $teamId -ChannelId $channelId -AuthContext $authContext
```

3. List channel members for a private or shared channel (GET `/teams/{team-id}/channels/{channel-id}/members`):

```powershell
$authContext = ./skills/graph/Connect-GraphApi.ps1 -AuthenticationType ManagedIdentity -Environment AzureCloud
./skills/teams/Get-TeamsMember.ps1 -TeamId $teamId -ChannelId $channelId -AuthContext $authContext
```

## Prerequisites
- Required modules:
  - Microsoft Graph authentication and session management modules (installed by `prerequisites/Install-RequiredModules.ps1`)
- Required permissions:
  - Microsoft Graph application permissions for Teams operations, typically `Group.ReadWrite.All`

## Related Docs
- [Auth Patterns](../../docs/auth-patterns.md)
- [Token Chaining](../../docs/token-chaining.md)
- [Environment Endpoints](../../docs/environment-endpoints.md)
