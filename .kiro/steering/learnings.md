---
inclusion: manual
---

# Key Learnings

Hard-won lessons discovered during implementation. Consult before working on any domain.

## AWS Organizations

- The organization must exist manually before any script runs — it cannot be created via CloudFormation.
- New AWS accounts have a hidden account creation limit (4-5) below the Service Quotas default of 10. Request a quota increase to at least 15 before provisioning.
- The Service Quotas API cannot reliably query the Organizations account limit.
- `AWS::Organizations::Account` does not close accounts on stack deletion — accounts are implicitly retained.
- Account emails are blocked for 90 days after an account is closed. Plan email addresses accordingly.

## Service Control Policies (SCPs)

- SCPs do not grant permissions — they only restrict the maximum available permissions. A `FullAWSAccess` or equivalent Allow policy must also be attached for any permissions to work.
- SCPs do not apply to the Management account — only to member accounts and OUs.
- `AWS::Organizations::PolicyAttachment` does **not exist** in CloudFormation. Use the `TargetIds` property directly in `AWS::Organizations::Policy` to attach a policy to OUs or accounts at creation time.
- `TargetIds` in `AWS::Organizations::Policy` requires the OU/account **ID** (e.g. `ou-xxxx-xxxxxxxx`), not the ARN. Export both `Id` and `Arn` from `2-ous.yaml` to support both use cases.
- Control Tower creates and manages its own SCPs (`aws-guardrails-*`) — do not modify, delete, or detach them. They protect CT infrastructure (Config, IAM roles, Lambda, SNS, EventBridge, S3 buckets).
- CT guardrails already cover: Config recorder/delivery channel, CT IAM roles, root user access, region deny, CT S3 buckets. Do not duplicate these in custom SCPs.
- Custom SCPs should complement CT guardrails — focus on what CT does not protect: GuardDuty, CloudTrail, IAM Access Analyzer, Security Hub, RAM external sharing, Identity Center SAML provider.
- Apply custom SCPs to Infrastructure and Workloads OUs. Leave Security OU exclusively managed by Control Tower.
- SCPs are enabled automatically by Control Tower when the Landing Zone is deployed — no need to enable them manually before deploying custom SCP stacks.

## Resource Control Policies (RCPs)

- RCPs restrict who can **access resources** — they are the complement to SCPs which restrict what identities can **do**. Both use the same `AWS::Organizations::Policy` resource type with different `Type` values (`SERVICE_CONTROL_POLICY` vs `RESOURCE_CONTROL_POLICY`).
- RCPs apply on the **resource side** of the authorization evaluation — even if a resource policy or IAM policy explicitly allows external access, an RCP can override it and deny the request.
- RCPs do not apply to the Management account — same as SCPs.
- The primary use case is the **identity data perimeter**: deny access to resources from principals outside the organization using `aws:PrincipalOrgID` condition.
- Always include exceptions for `aws:PrincipalIsAWSService: true` — AWS services acting on behalf of your org (CloudTrail, Config, Lambda) must be able to access resources like S3 and DynamoDB.
- Always include **confused deputy protection** — a separate statement that checks `aws:SourceOrgID` when `aws:PrincipalIsAWSService` is true, preventing attackers from using compromised AWS service roles to exfiltrate data to external accounts.
- Use the tag `dp:exclude:identity=true` on resources that should be intentionally accessible externally (e.g. public S3 buckets for static asset distribution). The RCP conditions use `StringNotEqualsIfExists` to skip enforcement for tagged resources.
- RCPs must be enabled before deploying — use `aws organizations enable-policy-type --root-id <root-id> --policy-type RESOURCE_CONTROL_POLICY`. Unlike SCPs, Control Tower does not automatically enable RCPs. The `create.sh` and `update.sh` scripts handle this automatically.
- `enable-policy-type` returns `PolicyTypeAlreadyEnabledException` if RCPs are already enabled — always add `|| true` to prevent `set -e` from terminating the script on re-runs.

## Control Tower

- Control Tower LZ v4.0 does not define organization structure in the manifest — accounts must be placed in an OU under root before creating the Landing Zone.
- `enable-baseline` is asynchronous — must poll `get-baseline-operation` until status is SUCCEEDED or FAILED.
- `enable-baseline` on an OU also enrolls all accounts already inside it.
- Never close accounts managed by Control Tower before decommissioning the Landing Zone.
- Legacy regional ARNs (`arn:aws:controltower:{region}::control/...`) do not work for guardrails. Always use global Control Catalog ARNs (`arn:aws:controlcatalog:::control/...`).

## Account Factory (Service Catalog)

- Account Factory requires both `ProductId` + `ProvisioningArtifactId` — using `ProductName` alone fails when multiple provisioning artifacts exist with the same name.
- Scripts must query the Service Catalog API at runtime to get the active artifact ID.
- Service Catalog portfolio access must be granted explicitly to the caller, even for the root user.
- Accounts created via Account Factory are already enrolled in Control Tower — no need to call `reset-enabled-baseline`.

## Identity Center

- The SSO service-linked role (`AWSServiceRoleForSSO`) must be created explicitly when setting up via API — it is not created automatically.
- Identity Center is not cleaned up during Landing Zone decommission — it must be deleted separately.
- SSO user emails are reusable across executions (Identity Center recreates them).
- SCIM provisioning from Entra ID requires Entra ID P1 license — not available on Free tier. Users must be created manually or via script.
- UPN in Entra ID must match the SSO user email used in Account Factory for SAML to work correctly.
- Entra ID Free tier supports unlimited users for SSO — no M365 license needed per user.
- **Control Tower creates groups and assignments automatically** — these are prefixed with `AWS` (e.g., `AWSControlTowerAdmins`, `AWSAccountFactory*`). The Management account user is assigned to these groups. Do not modify or delete them.
- **Account Factory creates one SSO user per account** and assigns them `AWSAdministratorAccess` to their respective account. These assignments are managed by Control Tower — do not remove them.
- **Entra ID integration is a manual prerequisite** — registering Identity Center as an enterprise app in Entra ID, exchanging SAML metadata, and enabling federation cannot be automated with CloudFormation or the AWS CLI. This step must be completed before the Identity domain scripts run.
- The Management account user must not be added to Identity Center groups for daily use — access to the Management account must remain exceptional and audited.
- **Entra ID groups are completely separate from Identity Center groups** — without SCIM (Entra ID P1 required), no group from Entra ID ever reaches Identity Center. Groups in Identity Center must be created and managed independently. Entra ID is only responsible for authentication (SAML assertion); Identity Center is responsible for authorization (group membership, Permission Sets, account assignments).
- **`aws ... --output text` returns multiple values tab-separated on a single line on macOS** — never use `while IFS= read` directly on the output. Use `echo "$VAR" | tr '\t' '\n'` to convert to newlines before iterating.
- **`put-instance-access-control-attribute-configuration` does not exist** — use `create-instance-access-control-attribute-configuration` for first-time setup and `update-instance-access-control-attribute-configuration` for subsequent changes. Check existence first with `describe-instance-access-control-attribute-configuration`.
- **`identitystore:UserId` is NOT a valid Source when using an external IdP (Entra ID)** — only `${path:...}` SAML attributes are valid as Source values in this configuration. Use `${path:emails[primary eq true].value}` for the user's email. The ABAC condition key in IAM policies is then `${aws:PrincipalTag/email}`.
- **Em dashes (`—`, U+2014) are not allowed in `Description` fields of `AWS::SSO::PermissionSet` and `AWS::IdentityStore::Group`** — the API only accepts the ASCII range `[\u0009\u000A\u000D\u0020-\u007E\u00A1-\u00FF]`. Use a regular hyphen (`-`) instead. Em dashes in YAML comments are fine.
- **Identity Center exposes two ACS URLs — both must be registered in Entra ID**: the Dual-stack URL (`https://<region>.sso.signin.aws/platform/saml/acs/<id>`) is used by the web portal, and the IPv4-only URL (`https://<region>.signin.aws/platform/saml/acs/<id>`) is used by the AWS CLI. Configuring only the Dual-stack URL allows portal login but breaks CLI SSO login with error `AADSTS50011`. Both must be added as Reply URLs in the Entra ID enterprise application.
- **Dual-stack ACS URL does not work with Entra ID in practice** — tested with both URLs configured in Entra ID and both in `~/.aws/config`. Only the IPv4-only URL (`https://<region>.signin.aws/platform/saml/acs/<id>`) works reliably for both portal and CLI login. The Dual-stack URL (`sso.signin.aws`) causes browser redirect failures. Configure Entra ID with the IPv4-only URL only, and use the IPv4-only `sso_start_url` format in `~/.aws/config`. This may change in future AWS or Entra ID updates.
