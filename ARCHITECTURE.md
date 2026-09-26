# Architecture

Design decisions and the reasoning behind each. Where a decision was reversed during the build, the original and the reason for the change are both recorded.

---

## Component boundaries

| # | Component | Trust boundary | Owner |
|---|---|---|---|
| 1 | HR system (SaaS) | Vendor ↔ organisation | HR |
| 2 | Worker record extract | Vendor ↔ organisation | HR |
| 3 | Azure Automation runbook | Internal | Identity |
| 4 | Managed identity | Identity plane | Identity |
| 5 | `/bulkUpload` endpoint | Identity plane | Microsoft |
| 6 | Entra provisioning service | Identity plane | Microsoft |
| 7 | Directory objects | Identity plane | Identity |
| 8 | Group membership → application access | Application plane | Application owners |

**The critical boundary is 3 → 5.** Everything upstream is data. At that boundary data becomes directory state, and directory state is access.

---

## Compliance Mapping

| Control | ISO 27001:2022 | NIST 800-53 r5 | Implementation | Evidence |
|---|---|---|---|---|
| Access revoked on termination | A.5.18 | AC-2(3) | Leaver detection on explicit date; multiple signals | Provisioning log entry, `active=false` |
| Automation runs least privilege | A.8.2 | AC-6 | Three scoped Graph permissions | Managed identity role assignments |
| Privileged accounts protected from automation | A.8.2 | AC-6(5) | Protected-prefix exclusion; restricted management AU | Excluded-record count in job output |
| Bulk change control | A.8.32 | CM-3 | Plan-then-execute, three thresholds, explicit override | Gate trip output and alert email |
| Segregation of duties | A.5.3 | AC-5 | Integrity stops require human resolution, not overridable | `Integrity check failed` job status |
| Audit trail of access decisions | A.8.15 | AU-2, AU-12 | Entra provisioning logs; reconciliation CSVs per run | Timestamped CSV set, emailed |
| Periodic access review | A.5.18 | AC-2(j) | Monthly reconciliation, orphans classified by owner | Orphan report by category |
| Identity proofing before provisioning | A.5.16 | IA-4 | Tiered matching; nothing below Tier 2 automated | Tier distribution in summary |
| Detection of unauthorised accounts | A.8.16 | AC-2(4) | Directory-to-HR orphan pass | `ENABLED, NO HR RECORD` category |

---

## Design decisions FAQ

### Why does provisioning write attributes only, never group membership?

Because attribute-driven access strips itself.

A mover workflow that manipulates groups has to remember everything it granted. Miss one and you get permission accretion — the accumulation that access reviews exist to find. Dynamic groups and access packages re-evaluate when `department` changes: out of the old, into the new, no script deciding what to remove.

The residue that still needs manual handling then becomes small enough to actually review.

### Why are integrity checks not overridable when the volume gate is?

They answer different questions.

The volume gate asks *"is this more change than normal?"* — and the honest answer might be yes, legitimately, during a restructure. An operator needs a way through.

Integrity checks ask *"would this write one person's data onto another person's account?"* There is no number at which that becomes acceptable. One is wrong.

So the volume gate sits behind a threshold and a `-Force` flag. Integrity checks sit **above** it in execution order, where neither can reach them.

### Why does a tripped gate leave the baseline unchanged?

If the run committed its state after halting, the anomaly would become the new normal. The next run would compare against a baseline that already contained the bad data, see no difference, and proceed.

The safety control would have hidden the problem instead of surfacing it.

### Why does reconciliation never write?

Read-only means it can run against production at any time without a change window, without approval, and without anyone hesitating. The moment it starts writing, it becomes something you schedule rather than something you run.

It also means privileged accounts can be **included** rather than excluded. An account excluded from your audit is an account you have stopped watching.

### Why tiered matching instead of a single rule?

Matching confidence is a spectrum, and the correct action differs by tier.

| Tier | Basis | Action |
|---|---|---|
| 0 | Conflict, collision, ID or name mismatch | **Blocker** — nothing syncs |
| 1 | `employeeId` exact | Already reconciled |
| 2 | Work email exact | Safe to seed automatically |
| 2b | Same local part, different domain | Verify first — the acquisition shape |
| 3 | Name + department | Human review |
| 4 | Name only | Human review, high scrutiny |
| 5 | No match | New hire, or no account needed |

Nothing below Tier 2 is automated. Two people named John Williams and an automated merge is permanent.

### Why is name verification applied at three separate points?

Because the same failure wears three disguises:

| Where | What can be wrong |
|---|---|
| ID match | The ID was reassigned to a different person |
| Email match | Two people share an address |
| Runtime, at the moment of writing | Either of the above, since the last reconciliation |

Same principle each time: **the identifier is evidence, not proof. Check the human behind it.**

### Why does eligibility gate account creation rather than the whole pipeline?

This was reversed during the build, and the original was a serious defect.

Eligibility originally filtered the worker list before the plan was built. But BambooHR's standard termination sets the employment status field to `Terminated` — **the same field eligibility reads**. A leaver was therefore removed before the plan existed, never reached the disable branch, and kept an enabled account indefinitely.

Nobody leaves the plan now. Eligibility is evaluated per record and only applies to people with no account: it decides whether one gets **created**. Anyone who already has an account is always tracked, so they can always be disabled.

The principle: **eligibility gates creation, lifecycle gates nothing.**

### Why is a rehire alerted rather than actioned?

Re-enabling a disabled account is security-sensitive. Someone terminated for cause and subsequently marked active in HR might be a data error — or worse.

So a rehire is classified, excluded from upload, and emailed to a human. It does **not** block the run, because it concerns one person's status rather than the integrity of everyone else's data.

That distinction generalises: **hard stop when data integrity is at risk; alert without blocking when it is a judgment call about one person.**

### Why does the percentage gate exclude skipped and ineligible records?

The denominator should be the population that can actually be affected.

Former employees with no account and people not entitled to one cannot be harmed by a bad feed. Counting them dilutes the percentage and lets a genuine mass event through. Three changes out of 109 records is 2.8%; out of the 8 people who actually have or are getting accounts, it is 37.5%.

The second number is the honest one.

### Why is the HR email not trusted as the UPN?

Three rules, each preventing a specific failure found in testing:

1. **Existing account** → always the directory's own UPN. HR must never rename an account. If `userName` maps to `userPrincipalName`, sending a differing address renames the user and breaks their sign-in.
2. **HR address on our domain** → use it.
3. **HR address on a foreign domain** → ignore it. Provisioning cannot create an account on an unverified domain, so the record would simply fail. Treat it as absent and derive one.

The deeper point: the email is an **output** of provisioning, not an input that decides it. Using it as the eligibility gate was circular, and it skipped exactly the new hire the pipeline exists to serve.

### Why are terminations detected on a date rather than a status flag?

A termination date is entered when notice is given, so it is known weeks ahead and offboarding can be pre-staged. Status often does not flip until payroll closes — days after the person has physically left. That lag is the access window the pipeline exists to close.

Status values remain as backstops. Any one signal is enough, because a single missing field must never be the reason an account stays open.

### Why is a leaver never inferred from absence in the feed?

Because absence is ambiguous. A record missing from an export could mean the person left, or it could mean the export truncated. Treating absence as termination is precisely how a bad feed becomes mass deprovisioning.

Accounts whose HR record has genuinely disappeared surface in reconciliation's orphan report instead, where a human decides.

### Why is `employeeId` kept on disabled accounts?

Three separate concerns, commonly muddled:

| Question | Answer |
|---|---|
| Should they have access? | No — account disabled |
| Should we know who they were? | **Yes** — keep `employeeId` |
| Should the account exist at all? | Eventually no — retention, not lifecycle |

Stripping the ID breaks rehires (the returning employee gets a second account), removes reconciliation's ability to distinguish a leaver from a broken link, and destroys the audit trail for offboarding. The ID goes when the account goes, on a documented retention schedule.

### Why a managed identity rather than a certificate?

The progression through the build was secret → certificate → managed identity, and each step removed a class of failure.

A client secret is a string, and strings leak into commits, screenshots and chat logs. A certificate's private key never travels — but certificates expire, and expiry is the classic silent 2am failure in unattended automation.

A managed identity has neither failure mode. Nothing stored, nothing to rotate, nothing to expire.

The HR API key remains a stored secret, held encrypted. That is the honest limit of the claim.

### Why is `202 Accepted` not treated as success?

Because it means *received*, not *processed*. Records can be accepted and then fail on scoping or matching with no error surfacing anywhere in the upload job.

The post-run check therefore alerts on three distinct conditions, and only the first looks like a failure:

- Records failed — visible in logs, but nobody reads logs at 3am
- Everything skipped — usually a mis-scoped filter, meaning provisioning ran and did nothing
- Zero events at all — the upload was accepted and then vanished

### Why compare headcount as its own control?

Found during testing: the HR system's UI showed 63 employees while its API returned 57. Six records were incomplete and never appeared in the endpoint. Nothing errored.

HR insists the person exists. IT insists they do not. Both are reading truthful data from different surfaces.

Match rates tell you nothing about records that never arrived to be matched. Counts do.

---

## What this architecture does not address

Stated plainly, because knowing where a control stops is part of the control.

- **An attacker with legitimate HR access.** Anyone who can create a worker record can create a real directory account. That is an HR access-control problem, entirely outside this boundary.
- **HR data quality.** Every control here assumes HR is broadly correct. Blank fields, wrong departments and late terminations are upstream.
- **Dynamic group evaluation latency.** Membership updates are asynchronous. There is a window after a department change where old access persists.
- **Token lifetime.** Removing group membership does not invalidate an existing access token. Continuous Access Evaluation closes this for supported applications; for others it does not.
- **Override discipline.** `-Force` exists and should. The control is only as strong as the culture around using it.
- **Non-human identity sprawl.** Reconciliation catches service accounts at the moment it runs. Nothing prevents new ones appearing.
