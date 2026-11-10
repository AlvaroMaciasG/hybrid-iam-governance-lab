# Hybrid IAM Governance Lab

A hands-on lab for practising how user access is granted, changed and removed in Microsoft Entra ID and Active Directory. It starts with a sample HR CSV for joiner, mover and leaver scenarios, then extends to directory synchronisation, application sign-in, access reviews and temporary privileged access.

The lab is an ongoing learning project, with room to add new IAM scenarios and refine existing workflows as the scope grows.

## Lab architecture

- **Cloud workflow.** PowerShell reads the HR CSV and uses Microsoft Graph to manage users and group memberships directly in Entra ID.
- **Hybrid workflow.** PowerShell reads the HR CSV and updates users and groups in Active Directory. Microsoft Entra Connect Sync synchronises the selected lab organisational units with Entra ID.

## Phase 1 — Cloud IAM

- [Lab setup](src/Phase1-EntraID/00-Setup-LabEnvironment.ps1) prepares the Microsoft Graph PowerShell modules and creates the test groups.
- [JML provisioning](src/Phase1-EntraID/New-JMLProvisioning.ps1) creates or updates accounts and manages group memberships based on the HR CSV. When the script disables an account, it calls `Revoke-MgUserSignInSession` to request session revocation.
- [Identity audit](src/Phase1-EntraID/Invoke-IdentityHygieneAudit.ps1) reports inactive accounts, MFA registration status and active assignments in selected Entra roles.

## Phase 2 — Hybrid identity

The [AD provisioning script](src/Phase2-Hybrid-AD/Invoke-ADJMLProvisioning.ps1) manages users and groups in the `iam.test` domain. I configured Entra Connect Sync with **Password Hash Synchronisation (PHS)** and limited synchronisation to the lab's `Users` and `Groups` organisational units.

I confirmed that three existing Entra users kept their object IDs after matching with their AD accounts. I tested a department change, offboarding and reactivation. I also changed a password in AD, signed in to Entra with the new password and completed Microsoft Authenticator setup.

- [Phase 2 setup and test results](docs/hybrid_identity.md)
- [Sample HR data](data/hr_feed.csv), [mover scenario](data/scenarios/hr_feed_mover.csv) and [leaver scenario](data/scenarios/hr_feed_leaver.csv)

## Phase 3 — Application access and governance

- **SAML 2.0 SSO.** I configured SAML Toolkit to use Entra ID for sign-in and confirmed a successful sign-in in the Entra logs.
- **OpenID Connect and OAuth 2.0.** I configured a Microsoft sample app to sign in with OpenID Connect. The app used the delegated `User.Read` permission to retrieve the signed-in user's profile from Microsoft Graph.
- **Access Reviews.** I approved one user's group membership and denied another's. After applying the decisions, I checked that only the approved user remained a direct member of the group.
- **Conditional Access.** I tested an MFA policy in report-only mode. The test sign-in succeeded, and the exported log showed that the policy would have required MFA if enabled.
- **Privileged Identity Management (PIM).** I made a test user eligible for the *Reports Reader* role. The user could read sign-in logs while the role was active. After manually deactivating it, I confirmed that access was denied.

[Phase 3 setup, test results and evidence](docs/application_access.md)

## Roadmap

| Phase | Topic | Status |
| --- | --- | --- |
| 1 | Cloud IAM and identity audit | Implemented |
| 2 | Active Directory provisioning and Entra Connect Sync | Implemented |
| 3 | Application access and governance | Implemented |
| 4 | Service principal audit, GitHub Actions and ServiceNow cases | Planned |
