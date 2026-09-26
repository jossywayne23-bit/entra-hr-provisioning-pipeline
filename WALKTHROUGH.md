# Walkthrough

Reproducible build from an empty tenant. Roughly a day's work, most of it waiting on module imports and provisioning latency.

---

## Prerequisites

| | |
|---|---|
| Microsoft Entra ID | P1 minimum; P2 for the governance layer above this |
| Azure subscription | Automation Accounts require one; the free tier covers 500 job-minutes/month |
| HR system | BambooHR trial, or any HRIS with a REST API returning employment data |
| Verified domain | Generated UPNs are rejected on unverified domains |
| Global Administrator | Required once, to grant Graph permissions to the managed identity |

---

## 1 — Automation Account

Azure portal → Automation Accounts → Create.

**Advanced tab → System assigned identity → ON.** Enable it at creation; adding it later works but is easy to forget.

After creation, open **Identity** and copy the **Object (principal) ID**.

---

## 2 — Grant Graph permissions to the managed identity

**This is the step that silently breaks everything if skipped.** The portal will not assign Graph *application* permissions to a managed identity. It must be PowerShell.

Skip it and the runbook authenticates successfully, then returns nothing. No error, no exception — authentication works, authorisation does not.

Run from your own machine, signed in as a Global Administrator:

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All","Application.Read.All"

$miObjectId = "<Object ID from step 1>"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '00000003-0000-0000-c000-000000000000'"

$permissions = @(
    "SynchronizationData-User.Upload"   # POST to /bulkUpload
    "AuditLog.Read.All"                 # read provisioning logs
    "User.Read.All"                     # compare against live directory state
)

foreach ($p in $permissions) {
    $role = $graphSp.AppRoles | Where-Object { $_.Value -eq $p -and $_.AllowedMemberTypes -contains "Application" }
    if (-not $role) { Write-Warning "Permission '$p' not found"; continue }
    New-MgServicePrincipalAppRoleAssignment `
        -ServicePrincipalId $miObjectId -PrincipalId $miObjectId `
        -ResourceId $graphSp.Id -AppRoleId $role.Id
    Write-Host "Granted $p"
}
```

**Verify. Do not assume:**

```powershell
Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $miObjectId |
    Select-Object @{N='Permission';E={($graphSp.AppRoles | Where-Object Id -eq $_.AppRoleId).Value}}
```

Three rows expected. Running as Global Admin grants consent implicitly — there is no separate consent step for this path.

---

## 3 — Import modules

Automation Account → **Modules** → Add from gallery. Runtime version **7.2**.

Import in order, waiting for each to complete:

1. `Microsoft.Graph.Authentication`
2. `Microsoft.Graph.Users`

Do not import the full `Microsoft.Graph` module — it is enormous and slows every runbook start.

A half-imported module produces `The term 'Connect-MgGraph' is not recognized`, which reads identically to a typo. Check the Modules blade before debugging code.

---

## 4 — Automation variables

Automation Account → **Variables**.

| Name | Type | Encrypted | Purpose |
|---|---|---|---|
| `BambooHRApiKey` | String | **Yes** | HR API key |
| `BambooHRSubdomain` | String | No | HR tenant subdomain |
| `ServicePrincipalId` | String | No | Provisioning app — from its technical info |
| `JobId` | String | No | Provisioning job — same place |
| `PrimaryDomain` | String | No | Verified domain for generated UPNs |
| `AlertTo` | String | No | Alert recipient |
| `GmailAddress` | String | No | SMTP sender |
| `GmailAppPassword` | String | **Yes** | Google App Password, not an account password |
| `ExpectedHeadcount` | String | No | Headcount check; empty disables it |
| `SyncBlocked` | **Boolean** | No | Set by reconciliation |
| `SyncBlockedReason` | String | No | Set by reconciliation |

**`SyncBlocked` must be Boolean.** Created as a String it stores the text `"False"`, and `[bool]"False"` evaluates to `$true` — blocking the sync permanently.

---

## 5 — Confirm HR field aliases before writing any rules

The HR system's UI labels are not its API aliases. Getting this wrong produces a field that is silently absent, which passes existence checks and then fails every comparison.

```powershell
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("<apikey>:x"))
$fields = Invoke-RestMethod -Uri "https://api.bamboohr.com/api/gateway.php/<sub>/v1/meta/fields" `
    -Headers @{ Authorization="Basic $auth"; Accept="application/json" }

$fields | Where-Object { $_.name -match "Employment|Status|Termination" } |
    Select-Object id, name, alias
```

Two aliases matter:

- **Employment status** — the eligibility field. Usually `employmentHistoryStatus`.
- **Projected termination date** — **not** the same field as `terminationDate`. Its alias goes in `$termDateFields`.

Use the custom report endpoint, not the directory endpoint. The directory endpoint returns a thin fixed field set — no status, no dates — and cannot support leaver detection.

---

## 6 — Provisioning application

Entra admin centre → **Enterprise applications** → New → search **API-driven provisioning to Microsoft Entra ID**.

After creation:

1. **Provisioning** → Attribute mapping. Confirm the matching pair is `externalId` → `employeeId`. This is what lets the pipeline recognise accounts it created.
2. Copy the **service principal object ID** and the **synchronization job ID** from the app's properties into the Automation variables.
3. **Start provisioning.**

**Verify the matching pair before creating accounts at scale.** If `employeeId` is not written on create, every account the pipeline makes becomes unmatched on the next run and it will attempt to create them again.

---

## 7 — Runbooks

Automation Account → **Runbooks** → Create. Type **PowerShell**, runtime **7.2**.

| Name | Source |
|---|---|
| `Reconciliation` | `runbooks/Runbook-Reconciliation.ps1` |
| `HR-Sync` | `runbooks/Runbook-HRSync.ps1` |
| `Provisioning-Check` | `runbooks/Runbook-ProvisioningCheck.ps1` |

Paste, **Save**, then **Publish**. The test pane runs the *draft*; schedules run the *published* version. Editing and testing without publishing means the schedule keeps executing old code.

Set `$eligField`, `$eligStatuses`, `$termDateFields` and `$exclDepts` at the top of `HR-Sync` to the aliases confirmed in step 5.

---

## 8 — Reconciliation first, always

Run `Reconciliation` before any sync. It is read-only.

Expected output:

```
[*] Reading Entra ID directory...
    18 directory accounts
[*] Reading BambooHR...
    109 HR records
...
  1 - employeeId           1
  2 - email exact          1
  5 - no match           107
 Safe to seed now  : 1
 Directory orphans : 16
```

Three CSVs arrive by email: the full match report, the orphan list, and the safe-to-seed list.

**Resolve every Tier 0 blocker before proceeding.** They are excluded from safe-to-seed, fail the job, and set `SyncBlocked`.

---

## 9 — Seed Tier 2 matches

Only Tier 2. Nothing below is automated.

```powershell
Connect-MgGraph -Scopes "User.ReadWrite.All"
$rows = Import-Csv "<safe-to-seed csv>"
$log = foreach ($r in $rows) {
    try {
        $u = Get-MgUser -Filter "userPrincipalName eq '$($r.EntraUPN)'" -ErrorAction Stop
        if (-not $u) { throw "not found" }
        $before = $u.EmployeeId
        Update-MgUser -UserId $u.Id -EmployeeId $r.HRId
        [PSCustomObject]@{ Name=$r.HRName; UPN=$r.EntraUPN; Before=$before; After=$r.HRId; Result="OK" }
    } catch {
        [PSCustomObject]@{ Name=$r.HRName; UPN=$r.EntraUPN; Before=""; After=$r.HRId; Result="FAILED: $($_.Exception.Message)" }
    }
}
$log | Export-Csv "seed-log-$(Get-Date -Format 'yyyy-MM-dd_HHmm').csv" -NoTypeInformation
```

The `Before` column is the rollback data. Seed in batches, re-run reconciliation after each, and confirm rows climb the tiers.

---

## 10 — Dry run

```
HR-Sync → Test pane → PlanOnly: true → Start
```

Read the output top to bottom:

```
Values seen for 'employmentHistoryStatus':
    Terminated               99
    Full-Time                9
    (blank)                  1
Eligible for NEW accounts: 9 of 109  (all 109 remain in scope for lifecycle)
--- CHANGE PLAN ---
 New          : 3
 Updated      : 1
 Skipped      : 103  (already left, no account)
=== THIS RUN WOULD BE BLOCKED ===
  - 44.4% of workforce > threshold 30%
```

The values-seen block is the first thing to check. It turns an unexplained eligibility count into an auditable one.

---

## 11 — Lifecycle verification

Use throwaway accounts. One worker through every stage.

| Stage | Action in HR | Expected |
|---|---|---|
| **Joiner** | Eligible worker, no account | `New: 1`; `UPNs generated: 1` if HR holds no address |
| **Self-link** | Re-run after provisioning settles | `Unchanged` — confirms `employeeId` written on create |
| **Writeback** | Re-run | `Wrote <upn> back to HR` |
| **Mover** | Change department | `Updated: 1` |
| **Leaver** | Set projected termination date to yesterday | `Disabled: 1`, one record with `active=false` |
| **Rehire** | Clear the date | `Rehire: 1`, **zero uploads**, alert sent, account stays disabled |

On a small population the percentage gate will trip legitimately — five changes out of eight people *is* a large fraction. Raise `MaxPercentOfWorkforce` explicitly for the test rather than using `-Force`. Raising a threshold is a decision; forcing past a control is a reflex worth not building.

Run `Provisioning-Check` fifteen minutes after each real run. `202 Accepted` means received, not processed.

---

## 12 — Schedules

| Runbook | Cadence |
|---|---|
| `HR-Sync` | Hourly |
| `Provisioning-Check` | Hourly, **offset 15 minutes** |
| `Reconciliation` | Monthly |

The offset matters. Checking immediately after upload returns nothing and reads as a failure.

---

## Pitfalls

**No `Read-Host`.** Runbooks are non-interactive; a prompt hangs the job until timeout.

**Never `Write-Output` a secret.** Job history is visible to anyone with Reader on the Automation Account.

**Use `Write-Error`, not `Write-Warning`, for anything that should mark the job failed.** Warnings look fine in the job list, which means nobody notices.

**Set `$ErrorActionPreference = 'Stop'`.** Graph errors are non-terminating by default, and a `try/catch` that never fires is worse than none at all.

**Verify the writeback endpoint on one record** before enabling it. A 403 means the API key lacks write permission — which is a finding in its own right.
