---
inclusion: always
---

# Conventions

## Project Structure

- Private monorepo with one directory per infrastructure domain
- Each domain is independent with its own scripts and templates
- Public repos are clean snapshots (no real emails, no steering)
- `.kiro/steering/` is global context — not copied to public repos

## Naming

- Stack names: `acme-` + kebab-case for domain stacks (e.g. `acme-identity-groups`, `acme-org-guardrails`)
- OU abbreviations: sec (Security), infra (Infrastructure), env (Workloads)
- **Custom resource naming**: all project-owned resources (Permission Sets, groups, SCPs, IAM roles, etc.) use the `Acme` prefix to distinguish them from resources created by AWS tooling (Control Tower, Landing Zone, Account Factory). Examples: `AcmePlatformAdmin`, `Acme-Developers`, `AcmeDenySecurityServiceModifications`
- Resources visible in the AWS console use `Acme` + PascalCase (e.g. `AcmePlatformAdmin`, `AcmeDenySecurityServiceModifications`)
- Groups in Identity Center use `Acme-` + PascalCase with hyphens for readability (e.g. `Acme-Developers`, `Acme-Infrastructure-Admins`)
- CFN Logical IDs remain PascalCase without prefix (e.g. `DevelopersGroup`, `PlatformAdminPermissionSet`) — they are internal to the template

## Infrastructure-as-Code Principle

- **CloudFormation first**: all AWS resources are defined in CloudFormation templates. Bash scripts are used only when CloudFormation cannot model the operation (e.g., async polling, dynamic lookups, multi-step orchestration).
- Bash scripts serve as orchestrators: they resolve runtime values (IDs, ARNs), invoke `aws cloudformation deploy`, and poll for async operations — they do not replace CloudFormation.
- Manual steps (e.g., third-party IdP configuration) are documented in context files but not scripted.

## Scripts

- Main entry point: `start.sh` at the root — prompts for AWS profile and region, then runs a loop showing the domain menu
- Entry point per domain: `start.sh` in each domain directory — shows domain menu and launches operational scripts as subprocesses with `bash`
- Shared validations centralized in `common/validate.sh` — sourced by all domain `start.sh` scripts
- `AWS_PROFILE` and `REGION` are exported by the main `start.sh` and passed explicitly to domain subprocesses via inline environment variables (`AWS_PROFILE="$AWS_PROFILE" REGION="$REGION" PROJECT_PREFIX="$PROJECT_PREFIX" bash domain/start.sh`)
- Domain scripts check if `AWS_PROFILE`/`REGION`/`PROJECT_PREFIX` are already set before prompting — supports both main menu flow and direct execution
- `PROJECT_PREFIX` is an internal variable set in `start.sh` (default `Acme`) — it is not prompted to the user. If not set, `common/validate.sh` applies the default silently.
- Bash scripts use `set -e`
- Use `aws cloudformation deploy` (idempotent)
- Use `> /dev/null 2>&1` to suppress output from commands whose JSON output is not needed (omit `|| true` unless the command is allowed to fail)
- Capture operation IDs and poll for async operations
- Use `--query` and `--output text` (never `| [0]` with text output)
- Destructive operations (`delete.sh`) must require explicit confirmation with `[y/N]` prompt — default is `N` (cancel). Never default to yes on destructive operations.
- **Input-first principle**: all user input must be collected at the beginning of the script, before any AWS operations start. Never prompt the user mid-execution. This allows the operator to answer all questions upfront and then leave the script to run unattended. Applies to any input: confirmation prompts, optional feature flags, runtime values like IP addresses or IDs that cannot be resolved automatically.
- **Script output must be generic** — never print usernames, email addresses, personal names, or internal domain names in `echo` messages. Print resource types and statuses instead (e.g. `"Group memberships resolved."` not `"sheldon.cooper → group-id"`). Technical IDs (Account IDs, Operation IDs, ARNs) are acceptable when they have diagnostic value.

## Shell Compatibility

Scripts target macOS (BSD userland) as the primary execution environment. macOS is
UNIX-certified (BSD-based); Linux is UNIX-like (GNU-based). Both are supported, but
macOS BSD tools are the baseline — avoid GNU-only syntax.

Rules:
- `date`: use `date '+%H:%M:%S'` — BSD and GNU compatible. Never use `date -d` (GNU only)
- `sed`: always include the extension argument with `-i`, even if empty: `sed -i '' 's/foo/bar/' file` (BSD requires it; GNU accepts it)
- `grep`: never use `grep -P` (Perl regex, GNU only) — use `grep -E` for extended regex
- `awk`: standard POSIX `awk` syntax only — no GNU `gawk` extensions
- `readarray` / `mapfile`: not available in Bash 3 (macOS default before Homebrew) — use `while IFS= read` loops instead
- `${VAR,,}` and `${VAR^^}` (lowercase/uppercase): not available in Bash 3 — use `echo "$VAR" | tr '[:upper:]' '[:lower:]'` instead
- Prefer `printf` over `echo -e` for portable formatted output
- Use `/tmp/` for temporary files — available on both macOS and Linux

## Menu Style

All menus follow a consistent visual format:

```
========================================================================
  <Domain or Project Title>
========================================================================

  1) Option one  - Description
  2) Option two  - Description

  q) Quit

------------------------------------------------------------------------
  Select an option:
```

Rules:
- Separator width: 72 characters (`=` for header/footer, `-` for prompt separator)
- Each menu option on a single line — no wrapping
- Options indented with 2 spaces
- `q) Quit` is the universal exit/back option across all menus
- Domains not yet implemented show `*** In Development ***` between the `-` separators — remove it once the domain is implemented
- Prompt text: `Select an option:` (no brackets or option hints)
- Main menu header section (before the loop) shows profile/region prompts with visible defaults: `[default]`, `[us-east-1]`

## Domain Navigation

Each domain `start.sh` follows this structure:

- `validate.sh` is sourced once before the loop — not inside it
- A `while true` loop displays the menu and handles user input
- Each option launches the corresponding script with `bash "$SCRIPTS_DIR/script.sh"` — never `source`
- Using `bash` (not `source`) ensures the script runs in its own subprocess: if it fails with `exit 1`,
  the menu survives and shows `Press any key to continue...` before looping back
- The "Press any key" prompt uses `read -r -s -n 1` — the `-n 1` flag reads exactly one character
  without waiting for Enter, so any key press returns to the menu immediately
- `q` exits with `exit 0`
- Invalid options show an error and use `sleep 2 + continue` to return to the menu without the pause

Domain `scripts/` directory structure:

```
domain/
├── start.sh              # Menu loop — sources validate.sh once, then loops
├── common/               # Domain-specific shared scripts (optional)
└── scripts/
    ├── create.sh         # Option 1 — full setup from scratch
    ├── update.sh         # Option 2 — modify existing resources
    └── delete.sh         # Option 3 — tear down all resources
```

Each operational script must define its own path variables at the top, immediately after `set -e`:

```bash
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"
CFN_DIR="$SCRIPTS_DIR/../cloudformation"
```

All references to CloudFormation templates must use `"$CFN_DIR/template.yaml"` (quoted).

Domains not yet implemented use placeholder scripts that print `This option is not yet implemented.`

Menu option naming rules:
- Options 1/2/3 (Create/Update/Delete) always use generic descriptions — never mention specific services or resources. The domain evolves but the menu stays valid:
  - `1) Create  - Deploy all domain resources`
  - `2) Update  - Re-deploy and apply changes`
  - `3) Delete  - Remove all domain resources`
- Feature-specific options (e.g. `Enable SCIM`, `Rotate credentials`) may use specific names since they describe a distinct, named operation.

## CloudFormation

- Use `!GetAtt` within same template
- Use `!ImportValue` across stacks
- Use `!Ref` for parameters
- Logical IDs in PascalCase
- Account Factory uses `DependsOn` for sequential creation
- Guardrails use `DependsOn` to avoid throttling

## README Structure

Each domain README follows this section order:

1. **One-line description** — what the domain does
2. **Scope** — bullet list of what the domain manages
3. **Prerequisites** — what must exist before running the scripts
4. **Access Design / Resource Design** — tables and rationale (domain-specific)
5. **Usage** — how to run (menu and direct execution)
6. **Structure** — directory tree of scripts and templates
7. **Concepts** *(optional, at the end)* — explanations of the AWS services and design patterns used in the domain. Intended for learning and certification preparation. Operational content always comes before conceptual content — experienced operators skip to what they need; learners find context at the end.
