# AWS Infrastructure — Agent Guide

Private infrastructure-as-code repository that manages all AWS resources for a
multi-account enterprise environment. Organized by domain, each with independent
scripts and CloudFormation templates. The only AI tool used in this project is Kiro.

## Repository Structure

```
aws-infrastructure/
├── start.sh                   # Main entry point — launches domain menus
├── common/
│   └── validate.sh            # Shared validations (AWS profile, region, credentials)
├── organizations/             # Control Tower, OUs, accounts, guardrails, SCPs, RCPs
│   ├── start.sh               # Domain menu (Create, Update, Delete)
│   ├── scripts/               # create.sh, update.sh, delete.sh
│   ├── common/                # register-and-enroll.sh
│   └── cloudformation/        # 1-iam-roles, 2-ous, 3-accounts, 4-guardrails, 5-scps, 6-rcps
├── identity/                  # Identity Center, Permission Sets, groups, ABAC
│   ├── start.sh               # Domain menu (Create, Update, Delete, Enable SCIM)
│   ├── scripts/               # create.sh, update.sh, delete.sh, enable-scim.sh
│   ├── common/                # resolve-instance.sh
│   └── cloudformation/        # 1-permission-sets, 2-groups, 3-assignments
└── .kiro/steering/            # Kiro context files (always loaded)
    ├── project-context.md     # Architecture, CT config, SSO, Account Factory, Identity design
    ├── conventions.md         # Naming, script patterns, menu style, CFN-first principle
    └── learnings.md           # Hard-won AWS lessons by service
```

## How to Run

```bash
./start.sh
```

Prompts for AWS profile (default: `default`) and region (default: `us-east-1`),
then enters a loop showing the main domain menu:

```
========================================================================
  AWS Infrastructure
========================================================================

  Domains:

  1) Organizations  - Multi-account governance and structure
  2) Identity       - Access control and user management

  q) Quit

------------------------------------------------------------------------
  Select an option:
```

Selecting a domain launches that domain's menu. Press `q` at any menu to go
back or exit. Domain scripts can also be run directly — they prompt for
profile/region if not already set in the environment.

## Domain Status

| Domain | Status | Description |
|--------|--------|-------------|
| Organizations | ✅ Implemented | Control Tower LZ 4.0, OUs, Account Factory, guardrails, SCPs, RCPs |
| Identity | ✅ Implemented | Permission Sets, group-based assignments, Entra ID federation, ABAC |

## AWS Organization Structure

```
Root
├── Security OU        → Audit Account, Log Archive Account
├── Infrastructure OU  → Network Account, Shared Services Account
├── Workloads OU       → Dev Account, Prod Account
└── Suspended OU       → Closed accounts (managed outside CloudFormation)
```

## Key Technical Decisions

- **Navigation**: `start.sh` (root) exports `AWS_PROFILE`, `REGION`, and `PROJECT_PREFIX`; domain
  scripts inherit them via environment. `common/validate.sh` prompts for them
  only when running a domain script directly.
- **Account provisioning**: Security accounts via `AWS::Organizations::Account`;
  all others via Account Factory (`AWS::ServiceCatalog::CloudFormationProvisionedProduct`).
- **Guardrails**: Global Control Catalog ARNs only — regional ARNs do not work.
- **Identity**: Microsoft Entra ID as external IdP via SAML 2.0. SCIM not
  available on Entra ID Free tier.
- **Scripts**: Bash with `set -e`. CloudFormation deployed with `aws cloudformation deploy` (idempotent).

## Working in This Project

- Read `conventions.md` before writing any script or CloudFormation template.
- Read `learnings.md` before working on any AWS domain — contains hard-won lessons.
- Read `project-context.md` for deep technical details (CT config, Account Factory, SSO).
- Each domain is independent — changes in one domain should not affect others.
- Do not duplicate validation logic — use `common/validate.sh`.
