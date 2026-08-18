# DLL Conflict Mitigation

> **Purpose:** Document the assembly-version conflict risk inherent to loading multiple Microsoft PowerShell modules in the same session, and prescribe the mitigation strategy aligned with [DllPickle](https://github.com/SamErde/DLLPickle) by Sam Erde.

---

## The Problem

Many Microsoft PowerShell modules — `Az.*`, `Microsoft.Graph.*`, `ExchangeOnlineManagement`, `MicrosoftTeams`, and more — bundle their own copy of the **Microsoft Authentication Library (MSAL)** and related identity-stack DLLs (`Microsoft.Identity.Client`, `Microsoft.IdentityModel.*`, `System.IdentityModel.Tokens.Jwt`, etc.).

A single PowerShell 7 session can load **only one version** of a given assembly identity into the default `AssemblyLoadContext`. When two modules ship different versions of the same DLL, the first one loaded "wins" and the second can fail with:

```
Assembly with same name is already loaded
MissingMethodException
TypeLoadException
```

This breaks authentication for whichever module lost the race.

### Modules Used by This Toolkit That Are Affected

| Module | Bundled Identity DLLs | Conflict Risk |
|--------|----------------------|---------------|
| `Az.Accounts` | MSAL, Azure.Core, Azure.Identity, IdentityModel | **High** when loaded with Graph or MSAL.PS |
| `Microsoft.Graph.Authentication` | MSAL, Azure.Core, System.ClientModel | **High** when loaded with Az or MSAL.PS |
| `MSAL.PS` | `Microsoft.Identity.Client` | **High** when loaded after Az or Graph |
| `ExchangeOnlineManagement` (future) | MSAL, IdentityModel | **High** |
| `MicrosoftTeams` (future) | MSAL, IdentityModel | **High** |

> **Attribution:** The problem description and classification above are derived from the [DllPickle](https://github.com/SamErde/DLLPickle) project by Sam Erde, specifically its architecture blueprint and `dependency-policy.json` methodology. DllPickle is an open-source PowerShell module (MIT license) dedicated to solving this exact problem.

---

## The Solution: DllPickle

[DllPickle](https://github.com/SamErde/DLLPickle) solves this by **preloading a curated, compatible set of identity-stack assemblies into the default `AssemblyLoadContext` before service modules load**. Because the compatible version is already resident, subsequent module imports reuse it instead of attempting to load their own divergent copy.

Key design decisions from DllPickle that inform this project's alignment:

1. **Preload the MSAL + IdentityModel stack** — these are shared by default-ALC consumers (Exchange Online, Teams, Graph, Az) and benefit most from a single coherent version.
2. **Do NOT preload Azure SDK assemblies** (`Azure.Core`, `Azure.Identity`, `System.ClientModel`) on .NET 8+ — modern `Az.Accounts` and `Microsoft.Graph.Authentication` self-isolate these into private `AssemblyLoadContext`s. Preloading them into the default ALC would split type identity and break `Connect-AzAccount`.
3. **PowerShell 7.4+ / .NET 8 (`net8.0`)** is the supported runtime for the automated preloader. Windows PowerShell 5.1 lacks `AssemblyLoadContext` and cannot self-isolate; the mitigation there is manual load-order management.

> **Attribution:** The preload / block classification and runtime reasoning above are adapted from [DllPickle's Architecture Blueprint](https://github.com/SamErde/DLLPickle/blob/main/docs/Architecture.md) (§2–§3), with thanks to Sam Erde for the detailed runtime measurements and ALC ownership analysis.

---

## Alignment for This Project

This toolkit uses `Az.Accounts`, `Az.Resources`, `Az.Compute`, `Az.Monitor`, `Az.OperationalInsights`, `Az.SecurityInsights`, `Microsoft.Graph.Authentication`, and `MSAL.PS` — the exact module set most prone to these conflicts. To align with DllPickle's methodology:

### 1. Install DllPickle (Optional but Recommended)

```powershell
# One-time installation
Install-Module DLLPickle -Scope CurrentUser

# Or with PSResourceGet
Install-PSResource -Name DLLPickle -Scope CurrentUser
```

`Install-RequiredModules.ps1` now offers DllPickle as an optional installation.

### 2. Load DllPickle Before Any Service Module

In every session where you will use multiple Microsoft service modules:

```powershell
# Run this FIRST, before Import-Module Az.Accounts or Microsoft.Graph.Authentication
Import-Module DLLPickle
Import-DPLibrary -ShowLoaderExceptions -Verbose
```

`Import-DPLibrary` preloads the compatible identity stack. After this, load your Az and Graph modules normally.

### 3. Use the Conflict-Safe Loader Helper

This project provides `prerequisites/Import-ConflictSafeModules.ps1` as a convenience wrapper:

```powershell
./prerequisites/Import-ConflictSafeModules.ps1 -Modules @('Az.Accounts','Microsoft.Graph.Authentication','MSAL.PS')
```

This helper:
- Detects whether `DLLPickle` is installed and invokes `Import-DPLibrary` first.
- Falls back to a **manual load-order heuristic** if DllPickle is unavailable:
  1. `MSAL.PS` (lowest dependency surface)
  2. `Microsoft.Graph.Authentication`
  3. `Az.Accounts` and remaining `Az.*` modules
- Emits warnings when known-incompatible pairs are detected in the same session.

> **Attribution:** The load-order heuristic and "first one wins" fallback are inspired by DllPickle's inspection-tier helpers (`Get-ModuleImportCandidate`, `Find-DLLInPSModulePath`) and its platform-support contract (§1.2).

### 4. Check Your Environment

`Test-Prerequisites.ps1` now includes a **DllPickle readiness check**:

```powershell
./prerequisites/Test-Prerequisites.ps1 -Detailed
```

If DllPickle is missing and you have both Az and Graph modules installed, the test emits:

```
[Warn] DLLConflictRisk: Az.Accounts and Microsoft.Graph.Authentication are both installed.
       Install DLLPickle and run Import-DPLibrary before loading these modules in the same session.
       See docs/dll-conflict-mitigation.md for details.
```

---

## Runtime Behavior Notes

### If You See an Assembly Load Error Anyway

1. **Restart the PowerShell session** — once a conflicting assembly is loaded, the only remedy is a new process.
2. **Run `Import-DPLibrary` as the very first command** — even before dot-sourcing `Common.psm1`.
3. **Verify DllPickle is up to date** — DllPickle publishes new versions automatically when upstream MSAL releases ship. Keep it current:
   ```powershell
   Update-Module DLLPickle
   ```

### Module-Private ALCs (Advanced)

On PowerShell 7.4+ / .NET 8+, `Az.Accounts` (5.x+) and `Microsoft.Graph.Authentication` use **private `AssemblyLoadContext`s** for their own Azure SDK copies. This means:

- `Azure.Core` inside Az's private ALC is a **different type identity** than `Azure.Core` in the default ALC.
- You cannot pass `Azure.Core.TokenRequestContext` created in the default ALC into Az's private ALC.
- **Do not attempt to preload `Azure.Core`, `Azure.Identity`, or `System.ClientModel` yourself** unless you are specifically targeting .NET Framework / Windows PowerShell 5.1.

> **Attribution:** This ALC behavior analysis is reproduced from DllPickle's runtime measurements (§2, "The runtime model that drives every decision").

---

## References and Attribution

- **DllPickle** — [https://github.com/SamErde/DLLPickle](https://github.com/SamErde/DLLPickle)  
  MIT License. Copyright (c) Sam Erde.
- **DllPickle Architecture Blueprint** — [docs/Architecture.md](https://github.com/SamErde/DLLPickle/blob/main/docs/Architecture.md)  
  The authoritative source for preload/block classifications, ALC ownership findings, and the release/dependency-update contract.
- **DllPickle Deep Dive** — [docs/Deep-Dive.md](https://github.com/SamErde/DLLPickle/blob/main/docs/Deep-Dive.md)  
  User-facing explanation of the version-conflict problem.

All problem descriptions, classification methodology, and runtime behavior notes in this document are derived from the DllPickle project and are used here with gratitude and explicit attribution.
