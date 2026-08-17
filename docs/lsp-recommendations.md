# LSP Recommendations

> **Purpose:** Guide contributors on which Language Server Protocol (LSP) servers to configure for this project, ranked by value and aligned with the file types in the repository.
>
> **Last updated:** 2026-08-17

---

## 1. PowerShell Editor Services (High Priority)

**Files:** `.ps1`, `.psm1`, `.psd1` — 40+ files

This project is primarily PowerShell. PowerShell Editor Services provides syntax validation, undefined variable detection, cross-file symbol navigation, and type checking.

**What it catches:**
- Syntax errors before runtime
- Undefined variables (e.g., the `$effectiveAuthType` bug fixed in `Connect-DataverseApi.ps1`)
- Unused parameters and variables
- Type mismatches
- Missing cmdlet dependencies
- Cross-file symbol navigation (e.g., `Resolve-AuthContext` in `Common.psm1` referenced from `Connect-DataverseApi.ps1`)

**Setup:**
```powershell
# Install the module
Install-Module PowerShellEditorServices -Scope CurrentUser

# LSP command
pwsh -Command "Start-EditorServices"
```

**Configuration:**
```json
{
  "lsp": {
    "powershell": {
      "command": ["pwsh", "-Command", "Start-EditorServices"],
      "extensions": [".ps1", ".psm1", ".psd1"]
    }
  }
}
```

---

## 2. YAML Language Server (Medium Priority)

**Files:** `.yaml`, `.yml` — `config.yaml`

Validates schema, catches indentation errors, and ensures the multi-tenant configuration file structure matches expectations.

**What it catches:**
- Invalid indentation (YAML's most common failure mode)
- Duplicate keys
- Type mismatches if a JSON schema is provided

**Setup:**
```bash
npm install -g yaml-language-server
```

**Configuration:**
```json
{
  "lsp": {
    "yaml": {
      "command": ["yaml-language-server", "--stdio"],
      "extensions": [".yaml", ".yml"]
    }
  }
}
```

---

## 3. Bicep Language Server (Medium Priority)

**Files:** `.bicep` — currently none, but listed in project stack

`agents.md` explicitly lists "Bicep / Azure CLI" as part of the stack. Bicep is the modern Azure deployment language and a natural fit for infrastructure automation in this toolkit.

**What it catches:**
- Invalid resource declarations
- Missing required properties on Azure resources
- Type mismatches in Bicep parameters/outputs
- Compilation errors before `az deployment` runs

**Setup:** Install the Bicep CLI (ships with Azure CLI or standalone).

**Configuration:**
```json
{
  "lsp": {
    "bicep": {
      "command": ["dotnet", "exec", "/path/to/Bicep.LangServer.dll"],
      "extensions": [".bicep"]
    }
  }
}
```

---

## 4. JSON Language Server (Medium Priority)

**Files:** `.json` — currently none, but pervasive in REST payloads

While no standalone `.json` files exist, this project is fundamentally a JSON-in/JSON-out REST API toolkit. A JSON LSP becomes relevant when:
- ARM templates are added for deployment skills
- JSON configuration files replace or supplement YAML
- API request/response schemas are documented

**What it catches:**
- Malformed JSON
- Schema validation against ARM resource schemas
- Invalid property types and missing required fields

**Setup:**
```bash
npm install -g vscode-json-languageserver
```

**Configuration:**
```json
{
  "lsp": {
    "json": {
      "command": ["vscode-json-languageserver", "--stdio"],
      "extensions": [".json"]
    }
  }
}
```

---

## 5. Markdown Language Server (Low Priority)

**Files:** `.md` — 15+ files

Validates links between docs and ensures consistent formatting across documentation.

**What it catches:**
- Broken internal links (e.g., `[SKILL.md](../skills/dataverse/SKILL.md)` pointing to a moved file)
- Inconsistent heading levels
- Missing code block language tags

**Setup:**
```bash
# Option A: marksman
brew install marksman  # or download binary

# Option B: vscode-markdown-languageserver
npm install -g vscode-markdown-languageserver
```

**Configuration:**
```json
{
  "lsp": {
    "markdown": {
      "command": ["marksman", "server"],
      "extensions": [".md"]
    }
  }
}
```

---

## Not Recommended

| LSP | Reason |
|-----|--------|
| TypeScript / Deno | No `.ts`/`.js` files in project |
| Python / Pyright | No Python files |
| Docker | No Dockerfiles |

---

## Complete Configuration Example

```json
{
  "lsp": {
    "powershell": {
      "command": ["pwsh", "-Command", "Start-EditorServices"],
      "extensions": [".ps1", ".psm1", ".psd1"]
    },
    "yaml": {
      "command": ["yaml-language-server", "--stdio"],
      "extensions": [".yaml", ".yml"]
    },
    "bicep": {
      "command": ["dotnet", "exec", "/path/to/Bicep.LangServer.dll"],
      "extensions": [".bicep"]
    },
    "json": {
      "command": ["vscode-json-languageserver", "--stdio"],
      "extensions": [".json"]
    },
    "markdown": {
      "command": ["marksman", "server"],
      "extensions": [".md"]
    }
  }
}
```

---

## Bottom Line

PowerShell Editor Services is the only LSP that would have materially helped prevent the recently fixed Dataverse bugs (undefined variables, strict-mode property access). The others are nice-to-have documentation and infrastructure hygiene.
