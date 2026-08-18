# Contributing

Thank you for your interest in contributing to Microsoft Cloud API Skills!

## Getting Started

1. Fork the repository
2. Install prerequisites: `./prerequisites/Install-RequiredModules.ps1`
3. Verify your environment: `./prerequisites/Test-Prerequisites.ps1`
4. Run smoke tests: `./prerequisites/Test-Smoke.ps1`

## Adding a New Skill

When adding a new skill:

1. Follow the normalized auth parameter set defined in [`AGENTS.md`](AGENTS.md).
2. Use `Common.psm1` for auth context resolution, REST execution, and pagination.
3. Emit the mandatory warning if client secret auth is used.
4. Document service-specific caveats in `docs/patterns-and-caveats.md`.
5. Add a `SKILL.md` in the service directory with YAML front matter for skills.sh compatibility.
6. Update the status table in [`AGENTS.md`](AGENTS.md) and the file list in [`README.md`](README.md).

## Code Style

- PowerShell 7.2+ compatible
- Use `Verb-Noun` naming convention
- Pass explicit auth context objects; never rely on global state
- Validate required parameters before execution
- Return structured output (arrays/hashtables) on success

## Pull Request Process

1. Ensure all smoke tests pass
2. Update relevant documentation
3. Describe what the skill does and why it matters
4. Reference any related issues

## Agent-Assisted Contributions

This project welcomes agent-assisted contributions. If you're using Claude Code, Codex, or another coding agent:

1. Point your agent to [`AGENTS.md`](AGENTS.md) for the tool inventory and auth patterns
2. Share [`llms.txt`](llms.txt) for concise project context
3. The agent should follow the same contribution guidelines as human contributors

## Questions?

Open a discussion or issue on GitHub.
