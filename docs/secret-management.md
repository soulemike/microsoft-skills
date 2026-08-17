# Secret Management

> **Purpose:** Expand the secret handling rules in `agents.md` into a single operator-facing policy document.
>
> **Core principle:** No secret material is embedded in any skill. Secrets are externalized and consumed only through approved patterns.

---

## 1. Preference Hierarchy

The toolkit uses the following order of preference for authentication material:

| Preference | Method | Why it ranks here |
|------------|--------|-------------------|
| 1 | **Managed Identity** | No secret material exists in the runtime |
| 2 | **Federated Credentials** | No long-lived secrets are stored in CI/CD or external workloads |
| 3 | **Azure Key Vault** | Centralized retrieval is acceptable when MI or federation is unavailable |
| 4 | **Certificate** | Stronger than shared secrets, but still requires private-key handling |
| 5 | **Environment Variables** | Last resort for secrets; easiest to misuse and hardest to audit at scale |

Short version:

**Managed Identity > Federated Credentials > Key Vault > Certificate > Environment Variables**

---

## 2. What Counts as Secret Material

Treat the following as secrets:

- Client secrets
- Private keys
- Certificate passwords
- API keys
- Passwords
- Any reusable bearer or refresh token

These values require stronger handling than tenant IDs, client IDs, subscription IDs, or cloud names.

---

## 3. Approved Handling Patterns

### Managed Identity

Preferred anywhere the workload runs on a platform that can mint tokens directly.

**Result:** nothing secret is stored in the environment, file system, or pipeline definition.

### Federated Credentials

Preferred for GitHub Actions, Azure DevOps, GitLab CI/CD, and similar external workloads.

**Result:** the pipeline exchanges short-lived identity assertions instead of storing reusable credentials.

### Azure Key Vault

Acceptable when a higher-trust auth primitive is unavailable and the workload still needs to retrieve certificate paths, client secrets, or similar material at runtime.

The intended pattern is:

1. Authenticate the workload with its executing identity.
2. Retrieve the secret from Key Vault just in time.
3. Do not persist the secret in source-controlled configuration.

### Certificate from Controlled Storage

Acceptable when certificate-based auth is required and Key Vault integration is not yet implemented.

The skill should accept a **path or thumbprint reference**, not embedded certificate content.

### Environment Variables

Allowed only as the last resort for secret material.

If a skill must read a secret from an environment variable, it should validate that the value is present and guide the operator toward Key Vault or managed identity instead.

---

## 4. Hard Prohibitions

The following are explicitly disallowed:

- Embedding secrets in source code
- Committing secrets to configuration files in version control
- Logging secrets
- Accepting plain-text client secrets as ordinary string parameters
- Checking private keys into the repository

For client secrets, the normalized interface requires `SecureString` or runtime retrieval from a secure store.

---

## 5. Non-Secret Material Guidance

Not everything belongs in a secret store. The following are **non-secret identifiers**:

- `TENANT_ID`
- `CLIENT_ID`
- `SUBSCRIPTION_ID`
- `AZURE_ENVIRONMENT`
- `DATAVERSE_ENVIRONMENT_URL`

Environment variables are allowed for these values, but `agents.md` still recommends centralized configuration files because they are easier to audit and manage across environments.

| Material Type | Preferred Home | Acceptable Fallback |
|---------------|----------------|---------------------|
| Secret material | Managed identity / federation / Key Vault | Certificate path or env vars as last resort |
| Non-secret identifiers | Centralized config file (`yaml`, `json`, etc.) | Environment variables |

If non-secret values are read from environment variables, the skill should emit the documented advisory warning encouraging migration to centralized configuration.

---

## 6. Recommended Configuration Split

Use this mental model:

- **Config file**: tenant IDs, client IDs, environment names, endpoint URLs, profile names
- **Secret store / workload identity**: secrets, certificate access, private keys, exchange tokens
- **Repository**: only templates and placeholders such as `.env.example`

`.env.example` should contain placeholders and comments only. It should not contain actual secret values.

---

## 7. Operational Rules

- Prefer eliminating secrets over managing them.
- If a secret exists, centralize it.
- If a secret must briefly exist in an env var, validate it, avoid logging it, and plan to remove that dependency.
- Treat client secret auth as an exception path, not a baseline design.

Related docs:

- `docs/auth-patterns.md`
- `docs/multi-tenant-auth.md`
