# HR-Driven Identity Provisioning for Microsoft Entra ID

Unattended joiner-mover-leaver automation between an HRIS and Entra ID, running as Azure Automation runbooks on a managed identity, with a safety gate in front of every write and a read-only reconciliation control in front of the whole pipeline.

Built and live-tested against a real Entra tenant and a live BambooHR instance. Every claim below maps to an actual run — no illustrative output.

---

## Business Problem

A termination in the HR system does not disable the corresponding directory account. The two systems are decoupled. Access persists until a human remembers to remove it.

The standard fix is HR-driven provisioning. The problem with HR-driven provisioning is that it inherits the HR system's mistakes at machine speed:

> A truncated export, a shifted column, or a bad bulk update tells the pipeline that several hundred people were terminated. The pipeline is not malfunctioning. It is working perfectly on bad input, and it will disable those accounts in under two minutes.

On a plant floor that is not an IT inconvenience. It is whether people can badge in at shift change.

Microsoft's accidental deletion prevention does **not** cover this case — it is scoped to directory *sync* deletions, not disables driven by uploaded HR attributes. The safety threshold has to be built upstream.

### What this solves

| Problem | Control |
|---|---|
| Termination in HR leaves the account enabled | Leaver detection on explicit date, plus status backstops |
| Bad HR export disables the workforce | Three independent volume thresholds, plan-then-execute |
| HR and directory disagree on who someone is | Read-only reconciliation with tiered confidence matching |
| Provisioning creates duplicates for existing staff | `employeeId` reconciliation before any sync is permitted |
| Automation reports success while doing nothing | Post-run provisioning log check; `202 Accepted` is not proof |
| Credential expiry silently stops the pipeline | Managed identity — no stored credential to expire |

---

## Architecture

```
HR system (BambooHR / Dayforce)
      │
      ▼
RECONCILIATION RUNBOOK ── monthly, read-only ──────────┐
  tiered matching · conflict / collision / mismatch    │
  orphan classification · emails 3 CSVs                │
  sets the SyncBlocked flag                            │
      │                                                │
      ▼                                                │
HR-SYNC RUNBOOK ── hourly, managed identity            │
  ├─ blocker flag check                                │
  ├─ headcount reconciliation                          │
  ├─ schema + eligibility validation                   │
  ├─ INTEGRITY hard stops (not overridable)            │
  ├─ VOLUME gate (overridable, deliberately)           │
  └─ SCIM conversion → /bulkUpload (50 per request)    │
      │                                                │
      ▼                                                │
Entra provisioning service — decides create/update/disable
      │                                                │
      ▼                                                │
PROVISIONING-CHECK RUNBOOK ── 15 min later ────────────┘
  failures · all-skipped · zero-events
```

**The load-bearing decision:** provisioning writes **attributes only** and never touches group membership. Access layers react to the attributes, so a department change rearranges access without a workflow performing surgery.

Full design reasoning in [ARCHITECTURE.md](ARCHITECTURE.md).

---

## Compliance Mapping

| Control objective | Framework reference | How this implements it |
|---|---|---|
| Timely revocation of access on termination | ISO 27001 A.5.18 · NIST 800-53 AC-2(3) | Leaver detection on explicit termination date; disable propagates within the sync interval |
| Least privilege for automation identities | ISO 27001 A.8.2 · NIST 800-53 AC-6 | Three narrow Graph permissions, not `Directory.ReadWrite.All` |
| Protection of privileged accounts | NIST 800-53 AC-6(5) | Protected-prefix exclusion; restricted management AU for break glass |
| Segregation of duties in identity changes | ISO 27001 A.5.3 | Integrity hard stops require human resolution; not overridable by operator flags |
| Audit trail for access decisions | ISO 27001 A.8.15 · NIST 800-53 AU-2 | Entra provisioning logs; timestamped reconciliation CSVs retained per run |
| Periodic review of access | ISO 27001 A.5.18 | Monthly reconciliation with orphan classification by owner |
| Change control on bulk operations | NIST 800-53 CM-3 | Plan-then-execute with volume thresholds and explicit override |

---

## Implementation

### Runbooks

| Runbook | Cadence | Writes? | Purpose |
|---|---|---|---|
| `Runbook-Reconciliation.ps1` | Monthly | **No** | Proves both systems agree on identity before anything syncs |
| `Runbook-HRSync.ps1` | Hourly | Yes | Pulls HR, gates, posts SCIM to `/bulkUpload` |
| `Runbook-ProvisioningCheck.ps1` | Sync + 15 min | No | Catches records accepted then silently failed |

### The two classes of control

Deliberately separated, and the separation is the point.

| | Integrity checks | Volume gate |
|---|---|---|
| Asks | Would this write the wrong person's data? | Is this more change than normal? |
| Examples | Unreconciled · ID mismatch · name mismatch | Disables > 25 · changes > 100 · > 10% of population |
| Overridable | **No** | Yes — `-Force` or raised threshold |
| Why | There is no number of people-overwritten-by-the-wrong-person that becomes acceptable | A restructure genuinely is a mass event; an operator needs a way through |

Integrity checks sit **above** the volume gate in execution order, so `-Force` cannot reach them.

### Authentication

`Connect-MgGraph -Identity` — system-assigned managed identity. No client secret, no certificate, nothing to rotate or expire.

Graph permissions granted to the managed identity's object ID:

- `SynchronizationData-User.Upload` — post to `/bulkUpload`
- `AuditLog.Read.All` — read provisioning logs
- `User.Read.All` — compare against live directory state

The remaining stored secret is the HR system's API key, held as an encrypted Automation variable.

---

## Verification

Full lifecycle proven end to end against a live BambooHR instance and a real Entra tenant, September 2026.

| Stage | Evidence | Screenshots |
|---|---|---|
| **Reconciliation** | 109 HR records vs 18 directory accounts; tiers 0–5 classified; 3 CSVs emailed | [`screenshots/01-reconciliation`](screenshots/01-reconciliation) |
| **Joiner** | 3 accounts created; UPN derived where HR held no address | [`screenshots/02-joiner`](screenshots/02-joiner) |
| **Self-linking** | Next run reported `Unchanged: 5` — pipeline recognises its own work, `employeeId` written on create | [`screenshots/02-joiner`](screenshots/02-joiner) |
| **Writeback** | Generated UPN written back to the HR record | [`screenshots/02-joiner`](screenshots/02-joiner) |
| **Mover** | `Updated: 1` on a department change | [`screenshots/03-mover`](screenshots/03-mover) |
| **Leaver** | `Disabled: 1`, one record uploaded with `active=false` | [`screenshots/04-leaver`](screenshots/04-leaver) |
| **Rehire** | `Rehire: 1`, **zero records uploaded**, email sent, account left disabled | [`screenshots/05-rehire`](screenshots/05-rehire) |

### Controls observed firing

| Control | Observed output |
|---|---|
| Volume gate | `55.6% of workforce would change, exceeding 10%` — nothing uploaded |
| Integrity hard stop | `Integrity check failed — 1 unreconciled, 0 ID mismatch(es).` |
| Blocker flag | `Sync blocked: 2 blocker(s). Resolve reconciliation blockers first.` |
| Headcount check | `Headcount check: 109 vs expected ~109 — within tolerance (2)` |
| Eligibility audit | `Terminated 99 · Full-Time 9 · (blank) 1` |
| Rehire hold | `1 change(s) held back` + alert, zero uploads |

### Bugs found in live testing

**Twenty-one defects found and fixed during live execution.** Every one is documented with its real error message in [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

The dominant failure mode — seventeen of the twenty-one — was **silent success**: code that reported normal operation while doing nothing. A missing cmdlet, a state file committing after failure, non-terminating errors bypassing `try/catch`, a field never requested from the API, a name check whose input was never selected.

That pattern is why this pipeline has a post-run check, an explicit headcount comparison, and a dry run that reports whether the real run would be blocked. A crash tells you something is wrong. A false success does not.

---

## Repository Contents

```
├── README.md              ← this file
├── ARCHITECTURE.md        ← design decisions and the reasoning behind each
├── WALKTHROUGH.md         ← step-by-step build, reproducible from scratch
├── TROUBLESHOOTING.md     ← 21 defects: symptom, root cause, fix, production comparison
├── runbooks/              ← the PowerShell runbooks
├── screenshots/           ← run evidence by lifecycle stage
└── evidence/              ← exported CSVs with identifying data removed
```

---

## Status and Honest Limits

**Proven:** full JML cycle against a live HRIS, unattended, no stored directory credential.

**Not proven:** production scale. Largest run is 109 HR records against 18 directory accounts. Nothing here has touched a workforce of thousands, multiple acquired directories, or a live HRIS rollout.

**Not built:** duplicate detection after sync, access packages, dynamic group provisioning, quarterly access reviews. Those are the governance layer above this one.

**Environment:** Microsoft Entra ID P2, Azure Automation, PowerShell 7.2 runtime, BambooHR (trial) as the HR source. Dayforce-specific handling — XRefCode translation in particular — is designed but untested, as it requires a Dayforce tenant.
