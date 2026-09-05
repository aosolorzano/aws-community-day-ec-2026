# AWS Infrastructure — Multi-Account Enterprise on AWS

> Project presented at **AWS Community Day Ecuador 2026**

Infrastructure-as-code for a multi-account AWS environment that simulates how a
global software company operates: multiple teams, isolated environments, federated
identity, and enterprise-grade security controls — all automated with CloudFormation
and Bash, and built with [Kiro](https://kiro.dev) as the AI coding assistant.

---

## About This Project

This project simulates a production-grade AWS organization from scratch. The goal
is not a minimal lab setup — every design decision follows enterprise best practices,
regardless of the current scale (6 accounts, 4 users). The assumption is that good
habits do not scale down well: if a pattern is correct for a large enterprise, it is
implemented here too.

**What it simulates:**

- A software company with development teams connecting to AWS via corporate VPN
- Multiple isolated environments (Dev, Prod) across separate AWS accounts
- Federated identity via Microsoft Entra ID (SAML 2.0) — no IAM users for daily access
- A centralized governance layer (Control Tower) that every account is enrolled in
- Resource ownership enforced at the policy level via ABAC

**What you will find in this repo:**

- A reusable Control Tower Landing Zone reference with automated deployment workflows
- Account Factory provisioning for 6 accounts across 4 Organizational Units
- Identity Center with group-based access, Permission Sets, and Attribute-Based
  Access Control (ABAC) tied to the user's email from the Entra ID SAML assertion
- SCPs and RCPs implementing a security and data perimeter at the organization level
- A Bash menu system that orchestrates all CloudFormation deployments interactively

---

## Architecture

```
AWS Organization
│
├── Management account      — Control Tower, Organizations, Identity Center, DNS
│
├── Security OU
│   ├── Audit account       — AWS Config aggregation, Security Hub findings
│   └── Log Archive account — Centralized CloudTrail and Config logs
│
├── Infrastructure OU
│   ├── Network account     — Transit Gateway, VPN, Client VPN endpoint
│   └── Shared Services account — CI/CD pipelines, ECR, internal tooling
│
├── Workloads OU
│   ├── Dev account         — Platform development environment
│   └── Prod account        — Platform production environment
│
└── Suspended OU            — Closed accounts (email cooldown period)
```

**Identity flow:**

```
Developer (laptop)
    → authenticates via Microsoft Entra ID (SAML 2.0)
    → Identity Center resolves group membership
    → assumes a temporary role (Permission Set) in the target account
    → session tagged with email → ABAC enforced at every API call
```

---

## Key Design Decisions

**CloudFormation first.** Resources are defined in CloudFormation whenever AWS
provides a supported resource type. Bash resolves runtime values, invokes
`aws cloudformation deploy`, polls asynchronous operations, and handles the few
operations CloudFormation cannot model, such as Identity Store memberships and
enabling an Organizations policy type.

**ABAC via identity-enhanced sessions.** The `AcmeDeveloperAccess` Permission
Set enforces resource ownership at the policy level: developers can only modify
resources they created, identified by the `owner` tag matching their email from
the Entra ID SAML assertion. Read operations are unrestricted — developers can
observe the full environment for debugging.

**Defense-in-depth with SCPs and RCPs.** Service Control Policies restrict what
identities can do (nobody can disable GuardDuty or delete CloudTrail, not even
admins). Resource Control Policies enforce the identity data perimeter — even if
a resource policy allows external access, the RCP blocks it at the organization
level.

**External IdP, no SCIM.** Microsoft Entra ID handles authentication only (SAML
assertion). Identity Center handles authorization (groups, Permission Sets,
account assignments). Groups are managed independently in Identity Center because
SCIM requires Entra ID P1, which is not available on the Free tier used here.
This is a documented cost tradeoff, not an oversight.

**Account Factory for account vending.** Every workload account is provisioned
through Control Tower Account Factory (Service Catalog). Accounts are created
already enrolled in Control Tower — no manual baseline enrollment needed.

---

## Domains

| Domain | Description | Status |
|--------|-------------|--------|
| [Organizations](organizations/README.md) | Control Tower LZ 4.0, OUs, Account Factory, guardrails, SCPs, RCPs | ✅ Implemented |
| [Identity](identity/README.md) | Permission Sets, group-based assignments, Entra ID federation, ABAC | ✅ Implemented |

---

## Getting Started

### Prerequisites

- AWS CLI v2 installed and configured
- An AWS Organization already created:
  ```bash
  aws organizations create-organization --feature-set ALL
  ```
- A quota increase for "Maximum number of accounts" requested (at least 15)
- Microsoft Entra ID configured as an external IdP in Identity Center (manual step — see [Identity README](identity/README.md))

### Running the project

Create a local deployment configuration first:

```bash
cp config/example.env config/local.env
```

Complete every value in `config/local.env`. This file contains account and SSO
user details and is excluded from Git. The published templates intentionally do
not include deployable email addresses or personal identities.

```bash
./start.sh
```

Prompts for an AWS profile and region (both with defaults), then presents a
menu to navigate into any domain:

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

Each domain has its own menu with Create, Update, and Delete options. Press
`q` at any menu to go back or exit. Domain scripts can also be run directly:

```bash
# With environment variables already set
AWS_PROFILE=management-admin REGION=us-east-1 bash identity/start.sh

# Or let the script prompt for them
bash organizations/start.sh
```

---

## Repository Structure

```
.
├── start.sh                    # Main entry point — launches domain menus
├── common/
│   └── validate.sh             # Shared validations (profile, region, credentials)
├── config/
│   └── example.env             # Public template; copy to ignored local.env
├── organizations/
│   ├── start.sh                # Domain menu
│   ├── scripts/                # create.sh, update.sh, delete.sh
│   ├── common/                 # register-and-enroll.sh
│   └── cloudformation/
│       ├── 1-iam-roles.yaml    # IAM roles required by Control Tower
│       ├── 2-ous.yaml          # OUs and Security accounts
│       ├── 3-accounts.yaml     # Workload accounts via Account Factory
│       ├── 4-guardrails.yaml   # Control Tower guardrails
│       ├── 5-scps.yaml         # Service Control Policies
│       └── 6-rcps.yaml         # Resource Control Policies
├── identity/
│   ├── start.sh                # Domain menu
│   ├── scripts/                # create.sh, update.sh, delete.sh, SCIM setup guide
│   ├── common/                 # resolve-instance.sh
│   └── cloudformation/
│       ├── 1-permission-sets.yaml  # AcmePlatformAdmin, AcmeDeveloperAccess, AcmeReadOnlyAccess
│       ├── 2-groups.yaml           # Acme-* groups
│       └── 3-assignments.yaml      # 6 group → Permission Set → account assignments
└── .kiro/steering/             # Kiro context files (see below)
```

---

## Kiro

This project was built with [Kiro](https://kiro.dev), an AI coding assistant
for the terminal. The `.kiro/steering/` directory contains the context files
that Kiro loads to understand the project:

| File | Inclusion | Purpose |
|------|-----------|---------|
| `project-context.md` | Always | Architecture, account structure, SSO design, Control Tower config |
| `conventions.md` | Always | Naming rules, script patterns, CFN conventions, menu style |
| `learnings.md` | Manual | Hard-won lessons per AWS service — load before working on a domain |

`inclusion: always` means Kiro loads the file automatically in every session.
`inclusion: manual` means the file is only loaded when explicitly referenced
in the conversation (e.g. "load learnings.md before we work on Identity").

These files are intentionally included in this public repo as an example of
how to structure Kiro context for an infrastructure project. They contain no
sensitive data.

---

## License

MIT
