---
inclusion: always
---

# Project Context

## Project Philosophy

This project serves three simultaneous purposes:

1. **Research and learning** — hands-on experience with AWS services relevant to the enterprise market and AWS certification exams.
2. **Future MVP** — the architecture is designed to be commercially scalable, not just a lab exercise.
3. **Technical reference** — each domain produces a clean, documented implementation that can serve as a reference for articles and public repos.

**Design principle**: always apply enterprise best practices, regardless of current scale. If a feature is a best practice for a large enterprise (ABAC, session policies, tagging strategies, least-privilege policies, etc.), it is implemented here — even if the immediate environment only has 4 users or 2 accounts. The goal is real-world experience, not a minimal viable configuration.

This means: when a new AWS feature or capability is relevant to a domain, it should be evaluated and implemented if it represents a best practice — not deferred because the project is small.

## Business Model and Product Vision

**Primary objective**: simulate how a large global technology company operates to develop a SaaS platform MVP. The commercial aspect is secondary — the priority is understanding enterprise-grade architecture, security layers, team structures, and operational best practices as applied in large AWS-oriented organizations.

**Product**: a cloud-native B2B platform. Physical and software components are used as test workloads to validate the architecture end-to-end.

**Business model**: cloud-native B2B software — deployed in the **client's own AWS account**.
- The platform is deployed in the client's own AWS account, not hosted centrally.
- Target clients: enterprises and organizations that require data sovereignty and control over their own infrastructure.
- This model matches real enterprise procurement: the client owns the infrastructure, the vendor delivers and maintains the software.
- A centrally-hosted model for smaller clients may be evaluated in the future but is not the current focus.

**What is being simulated**: a global software development company with:
- Development teams across multiple regions connecting via corporate VPN
- Internal tooling (CI/CD, artifact registry, issue tracking) accessible only via VPN
- Multiple environments (Dev, Prod) isolated per account and connected via Transit Gateway
- Strict network segmentation — all inter-service communication is private

## AWS Account Structure and Topology

```
Organization (software development company)
│
├── Management account     — governance, Organizations, Identity Center, Route 53 (DNS)
├── Network account        — Transit Gateway hub, VPC peering, Client VPN endpoint
├── Shared Services account — CI/CD pipelines, ECR, internal tooling (VPN-only access)
├── Dev account            — platform development environment
└── Prod account           — platform certified demo environment

Client account (simulated enterprise client)
├── ECS Fargate            — Spring Boot API (backend services)
├── DynamoDB               — application data and state
├── EventBridge + Lambda   — event-driven data processing
├── Cognito                — authentication for client users
├── Amplify/S3             — operator dashboard (VPN-only access)
└── VPC Endpoints          — all AWS service traffic stays private
```

## Project Operator

All infrastructure scripts in this project are executed by the **Management account operator** — the root user (or an IAM user with AdministratorAccess) of the AWS Management account. This user:

- Has IAM credentials (access keys) configured in `~/.aws/credentials` under a named profile.
- Is NOT an SSO user — authentication is via static IAM access keys, not Identity Center.
- Is responsible for deploying all domains: Organizations, Identity.
- Must NOT be added to Identity Center groups for daily use — Management account access must remain exceptional and audited.

The SSO users (Sheldon, Leonard, Howard, Raj) are end users who access workload accounts via Identity Center after the Identity domain is deployed. They are not involved in running infrastructure scripts.

## Account Provisioning

- Security accounts (Audit, Log Archive): created with `AWS::Organizations::Account` in `2-ous.yaml` (needed before Landing Zone)
- All other accounts: created with `AWS::ServiceCatalog::CloudFormationProvisionedProduct` in `3-accounts.yaml` (Account Factory)
- Account Factory requires `ProductId` + `ProvisioningArtifactId` (obtained dynamically in scripts)
- Accounts are created sequentially (DependsOn) to avoid throttling (~5-10 min each)
- Account Factory creates accounts already enrolled in Control Tower (no reset-enabled-baseline needed)

## SSO Users

Each account gets an SSO user in Identity Center. Users are created in Microsoft Entra ID
and their UPN must match the SSO email used in Account Factory.

### User — Account — Profile mapping

| User | SSO Email | Account | Account ID | CLI Profile | Permission Set |
|------|-----------|---------|-----------|-------------|----------------|
| Sheldon Cooper | `sheldon.cooper@example.com` | Network | `<your-network-account-id>` | `sheldon-network` | `AcmePlatformAdmin` |
| Leonard Hofstadter | `leonard.hofstadter@example.com` | Shared Services | `<your-shared-services-account-id>` | `leonard-shared` | `AcmePlatformAdmin` |
| Howard Wolowitz | `howard.wolowitz@example.com` | Dev | `<your-dev-account-id>` | `howard-dev` | `AcmeDeveloperAccess` |
| Howard Wolowitz | `howard.wolowitz@example.com` | Prod | `<your-prod-account-id>` | `howard-prod` | `AcmeReadOnlyAccess` |
| Raj Koothrappali | `raj.koothrappali@example.com` | Prod | `<your-prod-account-id>` | `raj-prod` | `AcmePlatformAdmin` |
| Raj Koothrappali | `raj.koothrappali@example.com` | Dev | `<your-dev-account-id>` | `raj-dev` | `AcmeReadOnlyAccess` |

All SSO profiles use `sso_session = aws-demo` in `~/.aws/config`. Sessions are
activated with `aws sso login --sso-session aws-demo` before running any script
that targets a workload account.

### Account emails (AWS account identifiers, not used for login)

| Account | Email |
|---------|-------|
| Audit | `aws-sec-audit@example.cloud` |
| Log Archive | `aws-sec-log@example.cloud` |
| Network | `aws-network-account@example.cloud` |
| Shared Services | `aws-shared-account@example.cloud` |
| Dev | `aws-dev-account@example.cloud` |
| Prod | `aws-prod-account@example.cloud` |

### CLI profile per domain script

Domain scripts do NOT use the `AWS_PROFILE` exported by `start.sh` for workload
account operations. They use the account-specific SSO profile directly:

| Domain script operation | Profile used |
|------------------------|-------------|
| Organizations / Identity | `acme-mgmt` (IAM static keys — Management account) |

`AWS_PROFILE` (set by `start.sh`) is the Management account profile (`acme-mgmt`)
and is used only by Organizations and Identity domain scripts.

## Control Tower Configuration

- Landing Zone version: 4.0
- Baseline version: 5.0
- Home region: configurable (prompted at runtime, default us-east-1)
- Governed regions: single region (to minimize costs)
- Auto-enrollment: Enabled (INHERITANCE_DRIFT remediation type)
- Backup: Disabled
- Guardrails: Region deny and Deny root access keys (applied to Infrastructure, Workloads OUs)
- Control ARNs: Use global ARNs from Control Catalog (region-independent)
  - Region deny (OU-level): `arn:aws:controlcatalog:::control/ka8e3pkqefnjsxuyc26ji580`
  - Deny root access keys: `arn:aws:controlcatalog:::control/8ui9y3oace2513xarz8aqojl7`

## Identity Center + Entra ID

- Identity source: External identity provider (Microsoft Entra ID)
- Protocol: SAML 2.0
- SCIM: Not available (requires Entra ID P1 — current subscription is Office 365 Business Standard / Entra ID Free)
- UPN in Entra ID must match SSO user email in Account Factory
- Entra ID Free tier supports unlimited users for SSO (no M365 license needed per user)
- **Entra ID integration is a manual step** — there are no scripts for it. It is a prerequisite that must be completed before the Identity domain scripts run. The configuration involves: registering AWS IAM Identity Center as an enterprise app in Entra ID, downloading the SAML metadata, and uploading it to Identity Center via the console. This step is already completed.
- The Management account user is intentionally excluded from Identity Center — access to the Management account must remain exceptional and audited, not part of daily SSO usage.
- **Entra ID groups are NOT synchronized to Identity Center** — without SCIM (requires Entra ID P1), groups defined in Entra ID never reach Identity Center. Groups in Identity Center are managed independently via CloudFormation and scripts.
- **Role of each system**: Entra ID handles authentication only (validates who the user is via SAML assertion). Identity Center handles authorization (groups, Permission Sets, account assignments). The two group namespaces are completely separate.
- **Design decision**: In a production enterprise environment, both users AND groups should be synchronized from Entra ID to Identity Center via SCIM — this provides a single source of truth for group membership, automatic offboarding, and centralized audit. This project manages groups directly in Identity Center as a cost-justified approximation (Entra ID P1 required for SCIM is ~$6/user/month and not warranted for a research lab).

## Identity Domain Design

The `identity/` domain implements group-based access control on top of the Identity Center baseline created by Control Tower. It does not modify any groups or assignments created by Control Tower — it only adds new ones.

### Permission Sets

| Permission Set | Base Policy | Session Duration | Purpose |
|---|---|---|---|
| `AcmePlatformAdmin` | `AdministratorAccess` (AWS managed) | 8 hours | Full access for infra/platform engineers |
| `AcmeDeveloperAccess` | Custom inline policy | 8 hours | Service-scoped access for devs — no IAM, no billing |
| `AcmeReadOnlyAccess` | `ReadOnlyAccess` (AWS managed) | 4 hours | Audit and observability access |

All Permission Sets require MFA.

### Groups and Account Assignments

| Group | Member | Permission Set | Account |
|---|---|---|---|
| `Acme-Infrastructure-Admins` | sheldon.cooper | `AcmePlatformAdmin` | Network |
| `Acme-Platform-Admins` | leonard.hofstadter | `AcmePlatformAdmin` | Shared Services |
| `Acme-Developers` | howard.wolowitz | `AcmeDeveloperAccess` | Dev |
| `Acme-Developers` | howard.wolowitz | `AcmeReadOnlyAccess` | Prod |
| `Acme-Operations` | raj.koothrappali | `AcmePlatformAdmin` | Prod |
| `Acme-Operations` | raj.koothrappali | `AcmeReadOnlyAccess` | Dev |

Design rationale:
- Developers have full access in Dev but read-only in Prod — prevents accidental production changes.
- Operations has full access in Prod (to manage running services) but read-only in Dev.
- Infrastructure and Platform teams each own their respective accounts fully.

### ABAC and Identity-Enhanced Sessions

Identity-enhanced sessions are enabled on the Identity Center instance. This injects the user's email address (from the Entra ID SAML assertion) into every session context at role assumption time:

- `path:email` — the user's primary email address from the SAML assertion (`${path:emails[primary eq true].value}`)

**Note**: `identitystore:UserId` is NOT a valid source when using an external IdP (Entra ID). Only `${path:...}` SAML attributes are valid as Source values in this configuration.

The `DeveloperAccess` Permission Set uses this attribute to enforce ABAC:
- **Write operations** require `aws:RequestTag/owner` to equal `${aws:PrincipalTag/email}` — developers must tag new resources with their own email at creation time.
- **Modify/delete operations** require `aws:ResourceTag/owner` to equal `${aws:PrincipalTag/email}` — developers can only modify resources they created.
- **Read operations** are unrestricted within allowed services — developers can observe any resource for debugging and collaboration.

This pattern will be extended in the Workloads domain to enforce resource isolation per team at the infrastructure level.

### What Control Tower Creates (do not modify)

Control Tower automatically creates groups and assignments for the Management account user. These are prefixed with `AWS` (e.g., `AWSControlTowerAdmins`, `AWSAccountFactory*`) and must not be modified or deleted.

## Main Entry Point

The project is operated through a single entry point: `start.sh` at the root.

### Startup flow

```bash
./start.sh
```

On launch, `start.sh`:
1. Prompts for **AWS profile** (default: `default`) — the Management account profile (`acme-mgmt`)
2. Prompts for **AWS region** (default: `us-east-1`)
3. Sets `PROJECT_PREFIX="Acme"` internally (not prompted — hardcoded)
4. Sources `common/validate.sh` to verify the profile exists in `~/.aws/config` and `~/.aws/credentials`
5. Enters a loop showing the main domain menu

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

### Variable propagation

`start.sh` exports three variables that all domain scripts inherit:

| Variable | Source | Example value |
|----------|--------|---------------|
| `AWS_PROFILE` | Prompted at startup | `acme-mgmt` |
| `REGION` | Prompted at startup | `us-east-1` |
| `PROJECT_PREFIX` | Hardcoded in `start.sh` | `Acme` |

Domain scripts are launched as subprocesses:
```bash
AWS_PROFILE="$AWS_PROFILE" REGION="$REGION" PROJECT_PREFIX="$PROJECT_PREFIX" bash domain/start.sh
```

This means each domain runs in its own subprocess — if a domain script fails
with `exit 1`, the main menu survives and returns to the loop.

### Direct execution

Domain scripts can also be run directly without going through the main menu.
`common/validate.sh` detects that `AWS_PROFILE` and `REGION` are not set and
prompts for them before proceeding.

```bash
# Run a domain script directly
AWS_PROFILE=acme-mgmt REGION=us-east-1 bash identity/start.sh

# Or let validate.sh prompt for them
bash identity/start.sh
```

### Note on profile scope

`AWS_PROFILE` (propagated from `start.sh`) is the **Management account profile**
and is used by both domain scripts.

## Architecture

- `organizations/` domain handles: OUs, accounts (Account Factory), guardrails, Landing Zone, SCPs, RCPs
- `identity/` domain handles: Permission Sets, groups, account assignments (builds on CT baseline)
- **CloudFormation first**: all AWS resources are defined in CloudFormation. Bash scripts only orchestrate (resolve runtime values, invoke CFN deploy, poll async operations) or handle steps CFN cannot model.
- Each domain is independent with its own `start.sh` and `common/validate.sh` for shared validations.
- **Project variables**: `AWS_PROFILE`, `REGION`, and `PROJECT_PREFIX` are captured at startup in `start.sh` and propagated to all domain scripts via environment. `PROJECT_PREFIX` (default `Acme`) drives resource naming — PascalCase for console resources (`AcmePlatformAdmin`), lowercase with hyphen for stack names (`acme-identity-groups`).
