# Phase 3 — Application access and governance

I used Microsoft Entra ID to test application sign-in, review group membership and activate a directory role for a limited time. The five cases below were verified in the lab.

## SAML 2.0 single sign-on

- **Configuration.** I set up `IAM Lab - SAML SSO` as a SAML enterprise application in Entra ID, configured the SAML Toolkit reply URL and uploaded Entra's signing certificate to the Toolkit.
- **Check.** I started sign-in from SAML Toolkit as Carlos. The Toolkit opened an authenticated session, and the Entra sign-in log for `IAM Lab - SAML SSO` recorded a successful sign-in.
- **Result.** The application accepted the SAML assertion issued by Entra and signed in the test user.
- **Evidence.** [Successful Entra sign-in](evidence/phase-3/saml-sso-success.png).

## Access Reviews

- **Configuration.** I created a one-time review for `SG-LAB-SAML-Access`, a group managed in Entra. I approved Carlos and denied Elena.
- **Check.** I applied the decisions and checked the group's direct members. Carlos was the only member listed.
- **Result.** Applying the review kept the approved membership and removed the denied membership from the group.
- **Evidence.** [Review decisions](evidence/phase-3/access-review-decisions.png) and [direct group membership after applying the results](evidence/phase-3/access-review-members-after.png).

## OpenID Connect and OAuth 2.0

- **Configuration.** I registered a single-tenant application and configured [Microsoft's JavaScript SPA sample](https://github.com/Azure-Samples/ms-identity-javascript-tutorial/tree/main/2-Authorization-I/1-call-graph) to use the lab tenant and Microsoft Graph's delegated `User.Read` permission. The sample uses MSAL and the authorization code flow with PKCE.
- **Check.** I signed in as Carlos and selected **See Profile**. The sample displayed the job title returned by Microsoft Graph's `/me` endpoint.
- **Result.** OIDC handled user sign-in and OAuth 2.0 authorized the app to read the signed-in user's profile. In [Phase 1](../README.md#phase-1--cloud-iam), I used Microsoft Graph PowerShell for administrative provisioning and audit tasks.
- **Evidence.** [Microsoft Graph profile displayed in the SPA](evidence/phase-3/oidc-oauth-graph-profile.png).

## Conditional Access in report-only mode

- **Configuration.** I set `LAB - SAML MFA - Report Only` to require MFA for Carlos when accessing `IAM Lab - SAML SSO`, and left the policy in *Report-only* mode.
- **Check.** *What If* matched the policy. I then completed a SAML sign-in and checked the policy result in the exported Entra sign-in log.
- **Result.** The sign-in succeeded. The policy evaluation showed that the same sign-in would have required an additional MFA step with the policy enabled.

Selected fields from the policy entry in the exported sign-in log.

```json
{
  "displayName": "LAB - SAML MFA - Report Only",
  "enforcedGrantControls": ["Mfa"],
  "result": "reportOnlyInterrupted"
}
```

## Privileged Identity Management (PIM)

- **Configuration.** I assigned Carlos the *Reports Reader* role as eligible and activated it for one hour using his test account.
- **Check.** While the role was active, Carlos could read the tenant sign-in logs. I deactivated the role, checked that it was absent from **Active assignments**, and retried access in a fresh session. Entra denied access due to insufficient privileges.
- **Result.** Activating the eligible role granted temporary access to tenant sign-in logs. Deactivating it removed that access in the lab.
