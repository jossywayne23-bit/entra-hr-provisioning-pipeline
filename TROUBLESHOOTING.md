# Troubleshooting

Twenty-one defects found during live execution against a real Entra tenant and a live BambooHR instance. Each entry carries the actual error message or output, not a reconstruction.

**Seventeen of the twenty-one were silent failures** — code that reported normal operation while doing nothing. That pattern is the through-line of this project and the reason for most of its controls.

---

## Index

| # | Defect | Silent? |
|---|---|---|
| [1](#1-cmdlet-does-not-exist) | `Remove-MgGroupMember` does not exist | No |
| [2](#2-snapshot-committed-after-a-failed-run) | Snapshot committed after a failed run | **Yes** |
| [3](#3-graph-errors-bypassed-trycatch) | Graph errors bypassed `try/catch` | **Yes** |
| [4](#4-password-generator-failed-intermittently) | Password generator failed ~6.8% of the time | Partly |
| [5](#5-null-object-cascade-masked-the-real-error) | Null object cascade masked the real error | No |
| [6](#6-phantom-csv-row-from-excel) | Phantom CSV row from Excel | No |
| [7](#7-field-requested-was-not-returned-by-the-endpoint) | Field requested was not returned by the endpoint | No |
| [8](#8-tryparse-overload-could-not-be-resolved) | `TryParse` overload could not be resolved | No |
| [9](#9-if-as-an-expression-parsed-but-failed-at-runtime) | `if` as an expression parsed but failed at runtime | **Yes** at parse time |
| [10](#10-response-envelope-wrapped-instead-of-its-contents) | Response envelope wrapped instead of its contents | No |
| [11](#11-writeback-wrote-the-wrong-persons-address) | Writeback wrote the wrong person's address | **Yes** |
| [12](#12-writeback-ran-during-a-dry-run) | Writeback ran during a dry run | **Yes** |
| [13](#13-drift-detector-matched-on-exact-email-only) | Drift detector matched on exact email only | **Yes** |
| [14](#14-foreign-domain-address-used-as-the-upn) | Foreign-domain address used as the UPN | No |
| [15](#15-hr-address-would-have-renamed-an-account) | HR address would have renamed an account | **Yes** |
| [16](#16-movers-dropped-for-having-no-upn) | Movers dropped for having no UPN | **Yes** |
| [17](#17-eligibility-field-alias-was-wrong) | Eligibility field alias was wrong | **Yes** |
| [18](#18-name-check-input-never-selected-from-graph) | Name check input never selected from Graph | **Yes** |
| [19](#19-eligibility-filtered-leavers-out-of-the-plan) | Eligibility filtered leavers out of the plan | **Yes** |
| [20](#20-rehire-alert-placed-inside-the-batch-loop) | Rehire alert placed inside the batch loop | **Yes** |
| [21](#21-dry-run-exited-before-evaluating-any-gate) | Dry run exited before evaluating any gate | **Yes** |

---

## 1. Cmdlet does not exist

**Symptom**
```
WARNING: [Mover] Jewel — Failed: The term 'Remove-MgGroupMember' is not
recognized as a name of a cmdlet, function, script file, or executable program.
```

**Root cause**
The Microsoft Graph PowerShell SDK ships `New-MgGroupMember` but not a matching `Remove-MgGroupMember`. The correct cmdlet is `Remove-MgGroupMemberByRef`. The asymmetry has open GitHub issues dating to 2020 and persists in SDK 2.25.

**Fix**
`Remove-MgGroupMember` → `Remove-MgGroupMemberByRef -GroupId <id> -DirectoryObjectId <id>`

**Production comparison**
A managed IGA platform abstracts the SDK entirely. Writing directly against Graph means owning cmdlet-level accuracy — and verifying names against documentation rather than recalling them.

---

## 2. Snapshot committed after a failed run

**Symptom**
Two mover events failed. The next run reported zero events and made no attempt to retry.

**Root cause**
The state snapshot was written unconditionally at the end of the run. A failed run therefore recorded its intended changes as completed. The next run compared against that baseline, found no difference, and concluded there was nothing to do.

**The failure became permanently invisible.** No error, no retry, no trace.

**Fix**
Snapshot advances only when the failure count is zero. Fixing that exposed a second-order defect: failed records were still being checkpointed, so the snapshot said *retry* while the checkpoint said *skip*. Checkpointing now records successes only.

**Production comparison**
This is what transactional state management exists to prevent. Hand-rolled delta detection means hand-rolling commit semantics, and getting them wrong is silent by construction. It is the strongest argument for moving delta detection to the platform.

---

## 3. Graph errors bypassed try/catch

**Symptom**
```
New-MgUser_CreateExpanded: The specified password does not comply with password
complexity requirements. Status: 400 (BadRequest)
...
Aggregation Summary
 Events Executed  : 1
 Failures         : 0
Employee     Event  Status
Fanum Bright Joiner Success
```

Account creation failed. The run reported **Success** with zero failures.

**Root cause**
Graph SDK cmdlets raise **non-terminating** errors by default. They print and execution continues — straight past the failure to `$result = "Success"`. The `try/catch` never fired because nothing was thrown.

Every failure guard written into that script was inert for API errors.

**Fix**
`$ErrorActionPreference = 'Stop'` at script scope.

**Production comparison**
One line, and its absence silently disabled every other control in the file. Any PowerShell automation calling Graph should set this before anything else.

---

## 4. Password generator failed intermittently

**Symptom**
```
The specified password does not comply with password complexity requirements.
```
Appearing on some joiners and not others, with no pattern.

**Root cause**
```powershell
-join ((65..90) + (97..122) + (48..57) | Get-Random -Count 14 | ForEach-Object { [char]$_ })
```
Entra requires three of four character classes. Drawing fourteen characters from a combined pool *usually* lands on three. Measured over 2,000 samples: **6.8% produced non-compliant passwords.**

**Fix**
Build guaranteed characters from each class first, then shuffle. Measured after: 0 failures in 2,000.

**Production comparison**
Roughly one joiner in fifteen failing at random is worse than a consistent failure — it presents as bad luck rather than a defect, so nobody investigates.

---

## 5. Null object cascade masked the real error

**Symptom**
```
New-MgGroupMember_CreateExpanded: Invalid target for navigation property update.
URI must target an entity.
```

**Root cause**
`New-MgUser` had failed, so `$newUser` was null. `$newUser.Id` produced an empty string and the request URI was malformed. The second error was louder than the first and pointed at the wrong line.

**Fix**
Explicit null check after the create, throwing a clear message rather than letting a downstream error mask the cause.

**Production comparison**
Standard defensive practice. Worth noting that the *misleading* error cost more time than the original failure.

---

## 6. Phantom CSV row from Excel

**Symptom**
```
Get-MgUser_List: Unsupported or invalid query filter clause specified for
property 'userPrincipalName' of resource 'User'.
WARNING: [Mover]   — Failed: Cannot bind argument to parameter 'UserId'
because it is an empty string.
```
Note the blank employee name in the output.

**Root cause**
Deleting a row's *contents* in Excel rather than the row itself leaves a line of commas. `Import-Csv` produces a record with every field empty. The filter became `userPrincipalName eq ''`, which Graph rejects.

**Fix**
Reject rows lacking an id or email before processing, with a count reported.

**Production comparison**
Schema validation on ingest is table stakes for any file-based integration. The instructive part is that the *shape* was valid — it was the content that was empty.

---

## 7. Field requested was not returned by the endpoint

**Symptom**
```
Index operation failed; the array index evaluated to null.
```

**Root cause**
The code keyed on `employeeNumber`. BambooHR's `/employees/directory` endpoint returns a thin fixed field set that does not include it. The value was null for every record, and indexing a hashtable with a null key throws.

**Fix**
Key on `id` — always present in that response. Later replaced entirely by a custom report that returns exactly the fields the logic depends on.

**Production comparison**
The HR system has several identifiers that look interchangeable in the UI and are not: an internal record id, a human-facing employee number, sometimes a payroll id. Dayforce has the same problem with XRefCodes. Confirm which one the API actually returns before building on it.

---

## 8. TryParse overload could not be resolved

**Symptom**
```
Cannot find an overload for "TryParse" and the argument count: "2".
```

**Root cause**
`[datetime]::TryParse($s, [ref]$var)` requires the ref variable to already be typed as `DateTime`. Passing `$null` leaves the overload unresolvable.

**Fix**
```powershell
try { $termDate = [datetime]$w.terminationDate } catch { $termDate = $null }
```

**Production comparison**
Minor, but it halted the run entirely because `$ErrorActionPreference` was set to `Stop` — which is the correct behaviour.

---

## 9. `if` as an expression parsed but failed at runtime

**Symptom**
```
The term 'if' is not recognized as a name of a cmdlet, function, script file,
or executable program.
```

**Root cause**
```powershell
Set-AutomationVariable -Name 'X' -Value (
    if ($blockers.Count -gt 0) { "..." } else { "" })
```
Inside a grouping expression used as a parameter value, the parser treats `if` as a **command name**. It parses cleanly and then fails at execution looking for a command called `if`.

**Worth recording:** this was initially assessed as correct because a parse check passed. Parsing is not execution, and a parse check is not a test.

**Fix**
```powershell
$reason = if ($blockers.Count -gt 0) { "..." } else { "" }
Set-AutomationVariable -Name 'X' -Value $reason
```

**Production comparison**
The runbook crashed at its final statement, so the `SyncBlocked` flag was never reset — leaving the sync blocked indefinitely with a misleading error. A late-stage failure in a state-writing step has consequences beyond the step itself.

---

## 10. Response envelope wrapped instead of its contents

**Symptom**
```
 1 HR records
```
Expected 109. The single record had every field blank.

**Root cause**
```powershell
$hrWorkers = @(Invoke-RestMethod ...)    # wraps the envelope
```
The custom report returns one object *containing* an `employees` array. Wrapping the response produced an array of one — the envelope itself.

**Fix**
```powershell
$hrWorkers = @((Invoke-RestMethod ...).employees)
```
Note the additional bracket pair. A partial fix — adding `.employees` without the opening bracket — produced `At line:81 char:13 + }).employees)`.

**Production comparison**
Downstream code proceeded without error on a single meaningless record. A count assertion immediately after ingest would have caught it at the source.

---

## 11. Writeback wrote the wrong person's address

**Symptom**
```
Wrote george@wayneenterprise.site back to HR for Gain Cruz
```
Gain Cruz was flagged as an ID mismatch. The write went to George Crone's address.

**Root cause**
Writeback ran *before* the change plan was built, so it had no knowledge of integrity findings. It saw an HR record with no address and an account bearing that `employeeId`, and wrote the UPN back.

The effect would have been to make an incorrect link look legitimate in **both** systems.

**Fix**
Moved to after the integrity hard stop, and switched to reading the plan rather than the raw worker list — so only records classified as correct matches qualify.

**Production comparison**
The most dangerous defect in this list. A control that validates and a process that writes must be ordered, and the writer must consume the validator's output rather than the raw input.

---

## 12. Writeback ran during a dry run

**Symptom**
```
Wrote george@wayneenterprise.site back to HR for Gain Cruz
...
-PlanOnly: nothing uploaded, no alerts sent.
```

**Root cause**
Same placement defect. Writeback sat above the `-PlanOnly` return, so a dry run modified the HR system while reporting that it had changed nothing.

**Fix**
Same relocation resolved both.

**Production comparison**
A dry run must not change anything, anywhere. Its value is entirely in being trustworthy, and a dry run that writes is worse than no dry run at all.

---

## 13. Drift detector matched on exact email only

**Symptom**
A worker with an existing Entra account was classified `New`. Changing one character of the address in HR was sufficient.

**Root cause**
The drift detector performed exact-string email matching. Reconciliation matched on name at a lower tier; the hourly sync had no equivalent. Any divergence — even a single character — read as a new hire.

The result would have been a **duplicate account**, plus an inflated change percentage capable of tripping the volume gate for the wrong reason.

**Fix**
Added a name index with the same normalisation reconciliation uses. Only an unambiguous single match counts; shared names fall through.

**Production comparison**
Two tools applying different matching logic to the same population will disagree about the same person. Matching rules belong in one place.

---

## 14. Foreign-domain address used as the UPN

**Root cause**
An HR record carrying `bob@gmail.com` had that address used directly as the UPN. Entra cannot create accounts on unverified domains, so the record simply fails.

**Fix**
An HR address is accepted only if it is on the organisation's domain. Anything else is ignored and a UPN derived.

Verified: `bob@gmail.com` → `bob.external@wayneenterprise.site`

**Production comparison**
The email is an **output** of provisioning, not an input that decides it. Treating it as authoritative input is circular.

---

## 15. HR address would have renamed an account

**Root cause**
For an existing account, the HR address was sent as `userName`. Where that maps to `userPrincipalName`, a differing value **renames the account and breaks the user's sign-in**.

**Fix**
An existing account always keeps the directory's own UPN. HR cannot rename people.

Verified: HR held `fanum.bright@`, the directory held `fanum.b@`, and `fanum.b@` was sent.

**Production comparison**
Source-of-truth boundaries need to be explicit per attribute. HR owns employment facts. Identity owns the identifier.

---

## 16. Movers dropped for having no UPN

**Symptom**
```
 Updated      : 2
  Batch 1 accepted — 1 records
```

**Root cause**
A worker with an existing account but no HR email had no UPN computed — generation only ran for people *without* an account. The record was classified `Update` and then filtered out for lacking a UPN.

Movers for anyone without an HR address would have vanished silently.

**Fix**
Fall back to the directory's existing UPN.

**Production comparison**
Found only by comparing the plan count against the upload count. Two numbers that should agree and do not is a cheap, high-yield check.

---

## 17. Eligibility field alias was wrong

**Symptom**
```
Eligible: 0  ·  Out of scope: 109
```

**Root cause**
The rule read a field alias the HR API does not return. `$null -notin @('Full-Time','Part-Time')` evaluates to `True`, so every worker was declared ineligible.

**Fix**
Two guards. One aborts if the field is absent from the response. A second reports the distribution of values actually seen, and halts if the proportion of blanks exceeds a configured threshold.

```
Values seen for 'employmentHistoryStatus':
    Terminated               99
    Full-Time                9
    (blank)                  1
```

**Production comparison**
Presence is not population. A field can exist on every record and be blank on most of them — passing an existence check and then failing every comparison. The distribution output turns an unexplained number into an auditable one.

---

## 18. Name check input never selected from Graph

**Symptom**
An account whose `employeeId` had been reassigned to a different person was classified `Update` rather than flagged as a mismatch.

**Root cause**
```powershell
Get-MgUser -All -Property Id, UserPrincipalName, EmployeeId, Department, JobTitle, AccountEnabled
```
`DisplayName` was absent from the property list. With `-Property` specified, Graph returns only the named fields. `$existing.DisplayName` was therefore null, and the comparison guard `if ($hrName -and $entraName -and ...)` short-circuited to false.

**The check had never executed since the day it was written.**

**Fix**
Add `DisplayName` to the property list, plus a warning when it is empty.

**Production comparison**
A control whose input is never fetched is indistinguishable from no control. Any check depending on a selected field should assert that the field arrived.

---

## 19. Eligibility filtered leavers out of the plan

**Symptom**
A terminated employee with an active account produced no change of any kind. No disable, no alert.

**Root cause**
Eligibility filtered the worker list *before* the plan was built. BambooHR's standard termination sets the employment status field to `Terminated` — **the same field eligibility reads**.

A leaver was therefore removed before the plan existed, never reached the disable branch, and **kept an enabled account indefinitely.**

Verified: a terminated worker with an enabled account produced 0 of 1 records reaching the plan.

**Fix**
Nobody leaves the plan. Eligibility is evaluated per record and applies only to workers with no account, deciding whether one is **created**. Anyone with an existing account is always tracked.

Termination detection also widened to multiple signals — date passed, employment status terminated, or record status inactive — because a single missing field must never be the reason an account stays open.

**Production comparison**
The most consequential defect here. Access would have persisted after every standard termination, and no output would have indicated a problem. The principle it produced — **eligibility gates creation, not lifecycle** — is the single most important design rule in this pipeline.

---

## 20. Rehire alert placed inside the batch loop

**Root cause**
The alert sat inside the upload loop. Two consequences: it fired once per batch, and when nothing was uploadable the loop never executed, so the alert never fired at all.

The one circumstance in which a rehire most needs reporting — nothing else to upload — was exactly the circumstance in which it went silent.

**Fix**
Relocated outside the loop, before the failed-batch check, since rehires are excluded from upload and do not depend on it.

**Production comparison**
Alert placement is a design decision, not an afterthought. An alert nested inside conditional execution inherits that condition.

---

## 21. Dry run exited before evaluating any gate

**Symptom**
`-PlanOnly` reported a plan that would have been blocked by three separate thresholds, with no indication that anything was wrong.

**Root cause**
The `-PlanOnly` branch returned before the gate logic. A dry run therefore could not tell you whether the real run would proceed — only what it would attempt.

**Fix**
The dry run now evaluates every gate and reports the verdict without sending alerts:

```
=== THIS RUN WOULD BE BLOCKED ===
  - 1 unreconciled worker(s) — would HARD STOP (not overridable)
  - 44.4% of workforce > threshold 30%
-PlanOnly: nothing uploaded, no alerts sent.
```

**Production comparison**
A dry run that cannot tell you whether the real run would be blocked is half a dry run. It must evaluate everything and act on nothing.

---

## The pattern

Seventeen of twenty-one defects shared one shape: **something ran and did nothing, and nothing said so.**

- A cmdlet that did not exist
- A state file committing after failure
- Non-terminating errors bypassing error handling
- A field never requested from the API
- A field requested but never populated
- A check whose input was never selected
- A control that filtered out the records it existed to protect

A crash tells you something is wrong. A false success does not — and the absence of an error is not evidence of correctness.

Most of these were found by reading output that looked fine and noticing that two numbers which should agree did not. The controls that exist in this pipeline — the post-run check, the headcount comparison, the values-seen distribution, the dry-run verdict — are each a direct response to one of them.
