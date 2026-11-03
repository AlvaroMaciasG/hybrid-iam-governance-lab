# Hybrid IAM Governance Lab

A lab for practising how to create, update and disable user accounts in Microsoft Entra ID and Active Directory. A sample HR CSV describes each employee's department, job title and status.

I work in security operations. I built this lab to practise identity tasks such as granting access, changing a user's permissions when they move teams and removing access when they leave.

## Phase 1 — Cloud IAM

- [Lab setup](src/Phase1-EntraID/00-Setup-LabEnvironment.ps1) prepares the Microsoft Graph PowerShell modules and creates the test groups in Entra.
- [JML provisioning](src/Phase1-EntraID/New-JMLProvisioning.ps1) processes joiners, movers and leavers. It creates or updates cloud users, manages the lab groups and requests session revocation when disabling an account.
- [Identity audit](src/Phase1-EntraID/Invoke-IdentityHygieneAudit.ps1) reports inactive accounts, MFA registration status and active assignments in selected Entra roles.

## Phase 2 — Hybrid identity

The [AD provisioning script](src/Phase2-Hybrid-AD/Invoke-ADJMLProvisioning.ps1) reads the CSV and updates users and groups in the `iam.test` lab. Microsoft Entra Connect Sync runs on a separate server and syncs the selected lab OUs to Entra.

I checked that three existing Entra users kept their object IDs after matching with AD. I then tested a department change, offboarding and reactivation with Elena. I also tested a password changed in AD by signing in to Entra with Carlos and completing Microsoft Authenticator setup.

- [Phase 2 setup and test results](docs/hybrid_identity.md)
- [Sample HR data](data/hr_feed.csv) and [mover and leaver examples](data/scenarios)

## Roadmap

| Phase | Topic                                       | Status                                                                                                         |
| ----- | ------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1     | Cloud JML and identity audit                | Implemented                                                                                                    |
| 2     | Active Directory JML and Entra Connect Sync | Tested in the lab                                                                                              |
| 3     | Application access and governance           | Planned — SAML, OIDC, OAuth, Access Reviews, PIM, Conditional Access in report-only mode, and ServiceNow cases |
| 4     | Service principal audit and GitHub Actions  | Planned                                                                                                        |
