# Phase 2 — Hybrid Identity with AD and Entra

In phase 1, I worked with Entra ID users. In this phase, I used the same HR CSV to manage users in Active Directory (AD) and sync the changes to Entra. The PowerShell script works in AD. Entra Connect Sync handles synchronization.

## Lab environment

| System | Purpose |
| --- | --- |
| DC01 | Windows Server 2022 with Active Directory and DNS for the `iam.test` domain. |
| SYNC01 | Windows Server 2022 joined to `iam.test`, with Microsoft Entra Connect Sync. |
| Microsoft Entra ID | Cloud test environment with the accounts that were matched to AD. |

In AD, I created the `LAB-JML` OU with two child OUs, `Users` and `Groups`. The global security groups are in `Groups`.

| Purpose | Group |
| --- | --- |
| All active employees | `GG-JML-AllEmployees` |
| Human Resources | `GG-JML-Human-Resources` |
| Security Operations | `GG-JML-SecOps` |
| Infrastructure | `GG-JML-IT-Infrastructure` |

The [base CSV](../data/hr_feed.csv) contains four sample employees. The script uses the employee ID to check the user's identity and the `UserPrincipalName` field to set the sign-in name (UPN). The local domain remains `iam.test`. To reproduce the hybrid setup in another environment, add your test tenant's suffix to the AD forest and update the UPNs in local copies of all three CSVs to use that suffix. Save those copies with the `.local.csv` extension and pass them to the script with `-CsvPath`. If accounts already exist, check that their UPNs match and that the AD accounts also have the expected employee IDs and account names.

## How I tested the script

Run the commands in this section one at a time on **DC01**, from the repository folder in Windows PowerShell 5.1. Commands that read or change AD require the ActiveDirectory module and access to the lab domain.

I first ran the syntax and CSV checks. The test includes invalid input, such as a duplicate ID or an unknown department.

```powershell
.\src\Phase2-Hybrid-AD\Test-ADJMLInput.ps1
```

I then ran a simulation. `-DryRun` shows the planned changes and writes a local log without changing AD.

```powershell
.\src\Phase2-Hybrid-AD\Invoke-ADJMLProvisioning.ps1 -DryRun
```

After reviewing the simulation, I applied the base CSV. For each new account, the script asks for a temporary password and requires the user to change it at their first sign-in.

```powershell
.\src\Phase2-Hybrid-AD\Invoke-ADJMLProvisioning.ps1
```

I ran the script again with the same CSV and checked that it made no further changes. This is what **idempotent** means. By default, logs are saved in `logs/Phase2-Hybrid-AD/`.

## How I connected AD and Entra

1. On **SYNC01**, I installed Entra Connect Sync using the custom setup. I selected password hash synchronization (PHS) and included only the `Users` and `Groups` OUs under `LAB-JML`.
2. I first left the server in *staging mode*. In Synchronization Service Manager, I reviewed the pending changes for the Entra connector. In my test, I saw three users and four groups.
3. After checking the scope and sign-in names, I turned off staging mode and checked that the export to Entra completed successfully.
4. In the Entra portal, I checked that the three users were shown as synchronized from AD and that they still had the same object IDs as before.

To reproduce the setup from scratch, follow Microsoft's guides on [custom installation](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-install-custom) and [staging mode](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/how-to-connect-sync-staging-server).

## Verified results

I tested these cases in the lab on **November 1, 2026**.

| Test | Result |
| --- | --- |
| CSV validation | All 10 checks passed without accessing AD. |
| Account creation in AD | The missing active accounts were created. EMP004 was marked as terminated and was not created. |
| Second run | The accounts matched the base CSV, and the second run reported zero changes. |
| Role change | Elena moved from SecOps to IT-Infrastructure. In Entra, I checked her new job title, her membership in the Infrastructure group, and her removal from `GG-JML-SecOps`. |
| Offboarding | Elena's account was disabled in Entra, and her `GG-JML` group memberships were removed. |
| Reactivation | I went back to the base CSV and authorized the reactivation of EMP002. Elena was active in SecOps again. |
| Password and MFA | I changed Carlos's password in AD and used it to sign in to the Microsoft My Account portal. I registered Authenticator and completed sign-in. |

To repeat the role change and offboarding tests, use the [mover](../data/scenarios/hr_feed_mover.csv) and [leaver](../data/scenarios/hr_feed_leaver.csv) CSVs, respectively. Here is an example of a dry run for the role change.

```powershell
.\src\Phase2-Hybrid-AD\Invoke-ADJMLProvisioning.ps1 -CsvPath .\data\scenarios\hr_feed_mover.csv -DryRun
```

After reviewing the plan, run the same command without `-DryRun` in the lab. For offboarding, follow the same steps with `hr_feed_leaver.csv`. To restore the initial state, use the base CSV. If EMP002 is disabled, explicitly add `-ReactivateEmployeeId EMP002`, first in the dry run and then in the actual run. After applying each change, wait for synchronization or start a delta sync cycle on **SYNC01**, then check the result in Entra.

I tested synchronization with three users who already existed in Entra. I tested sign-in with a synchronized password and Authenticator using Carlos's account.

## Scope

The script manages the `GG-JML` groups. Groups created directly in Entra during phase 1, such as `SG-RBAC-SecOps`, are managed separately. When I offboarded Elena, her memberships in those cloud groups remained in place. The offboarding test therefore covers disabling the account and removing memberships in the groups managed by the script.

The [Phase 3 guide](application_access.md) covers the application access and governance tests I ran in Entra, including an access review for a group managed in the cloud.
