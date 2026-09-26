<#
================================================================================
 RUNBOOK: HR-Sync
 Pulls workers from BambooHR, gates the change volume, and posts to Entra's
 API-driven inbound provisioning bulkUpload endpoint.

 WHAT'S DIFFERENT FROM THE LOCAL VERSION

   No CSV.        Reads the BambooHR API directly.
   No snapshot.   The gate compares against LIVE Entra state, not a file on
                  disk. Nothing to lose, corrupt, or leave on one machine —
                  and it detects drift from direct portal edits, which a
                  file-based snapshot cannot.
   No credential. Managed identity. Nothing stored, nothing to rotate,
                  nothing to expire at 2am.

 THE GATE STILL EXISTS, AND IT MATTERS MORE HERE
   /bulkUpload acts on whatever it receives. No threshold, no sanity check.
   Entra's accidental deletion prevention does NOT cover this — that control
   is scoped to directory SYNC deletions, not disables driven by uploaded HR
   attributes. And unlike the CSV version, no human ever sees this data
   before it uploads. The gate is the only thing between a bad API response
   and the directory.

 BEFORE FIRST RUN — two things must be confirmed:
   1. $eligField below must match a real BambooHR field alias. Check with
      /v1/meta/fields. If it is wrong, the run aborts with a clear message
      rather than silently declaring everyone ineligible.
   2. ExpectedHeadcount Automation variable (String). Set to the number the
      API should return. Leave empty to disable the count check.
================================================================================
#>

param(
    [switch] $PlanOnly,
    [switch] $Force,
    [int]    $MaxDisables           = 25,
    [int]    $MaxChanges            = 100,
    [int]    $MaxPercentOfWorkforce = 10
)

$ErrorActionPreference = 'Stop'


# ------------------------------------------------------------------------------
# Configuration from Automation variables
# ------------------------------------------------------------------------------
$apiKey       = Get-AutomationVariable -Name 'BambooHRApiKey'
$subdomain    = Get-AutomationVariable -Name 'BambooHRSubdomain'
$spId         = Get-AutomationVariable -Name 'ServicePrincipalId'
$jobId        = Get-AutomationVariable -Name 'JobId'
$alertTo      = Get-AutomationVariable -Name 'AlertTo'
$gmailAddress = Get-AutomationVariable -Name 'GmailAddress'
$gmailPass    = Get-AutomationVariable -Name 'GmailAppPassword'
$ourDomain    = Get-AutomationVariable -Name 'PrimaryDomain'

# --- Eligibility rule ---------------------------------------------------------
# A business rule, not a technical one. It should read as a sentence someone in
# HR could approve: "full-time and part-time staff get accounts; seasonal labour
# and contractors do not."
# VERIFY $eligField against /v1/meta/fields before first run.
$eligField    = 'employmentHistoryStatus'
$eligStatuses = @('Full-Time','Part-Time')

# Departments. An ALLOW list fails closed — a department nobody has thought about
# gets nothing until someone decides. A DENY list fails open — a new department
# gets accounts by default. For provisioning, failing closed is the right way
# round. Leave $allowDepts empty to fall back to the deny list.
$allowDepts   = @()
$exclDepts    = @('Seasonal Labour','Contractor')

# --- Leaver signals -------------------------------------------------------------
# Any ONE of these marks someone as gone. Several, because HR systems record
# termination in more than one place, and a single missing field must never be
# the reason an account stays open.
#   - date fields: add the alias of "Projected Termination Date" from
#     /v1/meta/fields — it is NOT the same field as terminationDate.
#   - status values: BambooHR's standard termination sets the employment
#     status itself to Terminated.
$termDateFields     = @('terminationDate')
$terminatedStatuses = @('Terminated')

# How much missing eligibility data is tolerable before this stops being a
# filter and starts being an outage. Blanks fail the rule and drop out silently;
# past this fraction that is a data-quality incident, not normal attrition.
$maxBlankEligPercent = 20

# Accounts automation must never touch, whatever else happens.
$protectedPrefixes = @('bg-','svc-','admin-')

Write-Output "HR-Sync starting — $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"


# ------------------------------------------------------------------------------
# Helpers — all defined before first use
# ------------------------------------------------------------------------------
function Send-Alert {
    param([string] $Subject, [string] $Body)

    # Write-Error marks the JOB as failed, so an Azure Monitor alert rule on
    # job failure catches this even if SMTP is blocked from the sandbox.
    # Belt and braces: an alert channel that fails silently is not an alert.
    try {
        $secure = ConvertTo-SecureString $gmailPass -AsPlainText -Force
        $cred   = New-Object System.Management.Automation.PSCredential($gmailAddress, $secure)
        Send-MailMessage -From $gmailAddress -To $alertTo -Subject $Subject -Body $Body `
            -SmtpServer "smtp.gmail.com" -Port 587 -UseSsl -Credential $cred -WarningAction SilentlyContinue
        Write-Output "  [alert emailed to $alertTo]"
    }
    catch {
        Write-Warning "  Email alert failed: $($_.Exception.Message)"
    }
}

# Employee IDs arrive inconsistently: "101", "101 ", "0101". Reconciliation
# normalises them; this must too, or the two tools disagree about the same
# person — one matches and the other calls them a new hire.
function Get-NormalizedId {
    param($Id)
    if ($null -eq $Id) { return $null }
    $s = $Id.ToString().Trim().ToLower()
    if ($s -match '^\d+$') { return [string][int]$s }   # strip leading zeros
    return $s
}

# Same normalisation Reconciliation uses, so both tools agree on what counts as
# the same name: punctuation stripped, lowercased, parts sorted so word order
# stops mattering ("Okafor, Chidi" == "Chidi Okafor").
function Get-NormalizedName {
    param([string] $Name)
    if (-not $Name) { return $null }
    $clean = ($Name -replace "[^\p{L}\s]", " ") -replace "\s+", " "
    $parts = $clean.Trim().ToLower() -split " " | Where-Object { $_.Length -gt 1 }
    return ($parts | Sort-Object) -join " "
}

function New-UpnFromName {
    param([string] $First, [string] $Last, [string] $Domain)

    $norm = {
        param($s)
        if (-not $s) { return "" }
        $flat = [Text.Encoding]::ASCII.GetString(
            [Text.Encoding]::GetEncoding('Cyrillic').GetBytes($s))
        ($flat -replace "[^\p{L}]", "").ToLower()
    }

    $f = & $norm $First
    $l = & $norm $Last
    if (-not $f -or -not $l) { return $null }
    return "$f.$l@$Domain"
}

function Get-UniqueUpn {
    param([string] $BaseUpn, [hashtable] $TakenLookup)

    if (-not $TakenLookup.ContainsKey($BaseUpn.ToLower())) { return $BaseUpn }

    $local, $domain = $BaseUpn -split "@", 2
    for ($n = 2; $n -le 99; $n++) {
        $candidate = "$local$n@$domain"
        if (-not $TakenLookup.ContainsKey($candidate.ToLower())) { return $candidate }
    }
    return $null   # 99 collisions means something is wrong — fail loudly
}


# ------------------------------------------------------------------------------
# 0 — Honour the reconciliation blocker flag
# ------------------------------------------------------------------------------
if ([bool](Get-AutomationVariable -Name 'SyncBlocked')) {
    $reason = Get-AutomationVariable -Name 'SyncBlockedReason'
    Send-Alert -Subject "HR sync skipped — reconciliation blockers outstanding" -Body $reason
    Write-Error "Sync blocked: $reason. Resolve reconciliation blockers first."
    return
}


# ------------------------------------------------------------------------------
# 1 — Pull from BambooHR
# ------------------------------------------------------------------------------
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${apiKey}:x"))

# The directory endpoint returns a thin fixed field set — no status, no dates.
# A custom report lets us request exactly what the logic depends on, in one call.
$uri  = "https://api.bamboohr.com/api/gateway.php/$subdomain/v1/reports/custom?format=JSON"
$body = @{ fields = @(
    "id","displayName","firstName","lastName","workEmail",
    "department","jobTitle","status","hireDate",$eligField
) + $termDateFields | Select-Object -Unique } | ConvertTo-Json

try {
    $response = Invoke-RestMethod -Method POST -Uri $uri -Body $body -Headers @{
        Authorization  = "Basic $auth"
        "Content-Type" = "application/json"
        Accept         = "application/json"
    }
}
catch {
    Write-Error "BambooHR API call failed: $($_.Exception.Message)"
    return
}

$workers = @($response.employees)
Write-Output "Pulled $($workers.Count) workers from BambooHR"

# A truncated or empty API response is the silent killer here. Nobody eyeballs
# this data before it uploads, so an empty result would look to the gate like
# "everyone left the company".
if ($workers.Count -eq 0) {
    Send-Alert -Subject "ALERT: HR sync — BambooHR returned zero workers" `
               -Body "The API call succeeded but returned no employees. Nothing was uploaded. Investigate the source before re-running."
    Write-Error "BambooHR returned zero workers — aborting rather than treating this as a mass termination."
    return
}

# The HR UI can show people its API does not return — records missing required
# employment data never appear in the endpoint. Nothing errors. Match rates tell
# you nothing about records that never arrived, so compare counts directly.
$expectedRaw = Get-AutomationVariable -Name 'ExpectedHeadcount'
$expected    = if ($expectedRaw) { [int]$expectedRaw } else { 0 }

if ($expected -gt 0) {
    $delta = [math]::Abs($workers.Count - $expected)
    $tol   = [math]::Max(2, [math]::Round($expected * 0.02))
    if ($delta -gt $tol) {
        Send-Alert -Subject "HR sync — headcount mismatch" `
                   -Body "API returned $($workers.Count), expected ~$expected (tolerance $tol). Records may be missing from the source. Nothing was uploaded."
        Write-Error "Headcount mismatch: got $($workers.Count), expected ~$expected (tolerance $tol)."
        return
    }
    Write-Output "Headcount check: $($workers.Count) vs expected ~$expected — within tolerance ($tol)"
}

# A missing field that silently defaults is worse than an outage — the pipeline
# reports clean runs while an entire event type can never fire.
$required = @('id','workEmail','department','status')
$present  = $workers[0].PSObject.Properties.Name
$missing  = $required | Where-Object { $_ -notin $present }

if ($missing) {
    Send-Alert -Subject "HR sync — source missing required fields" `
               -Body "Missing: $($missing -join ', ').`n`nLeaver detection depends on 'status'. Without it no termination can be detected and this pipeline will report clean runs indefinitely."
    Write-Error "HR source missing required field(s): $($missing -join ', ')"
    return
}

# Eligibility decides who gets a directory account at all. The guard matters
# more than the rule: a missing field makes every comparison null, and null
# fails every membership test — so an absent field silently declares the
# entire workforce ineligible and nobody is ever provisioned.
if ($present -notcontains $eligField) {
    Send-Alert -Subject "HR sync — eligibility field '$eligField' missing from source" `
               -Body "Without it every worker evaluates as ineligible and nobody would be provisioned. Nothing was uploaded. Confirm the field alias against /v1/meta/fields."
    Write-Error "Eligibility field '$eligField' not returned by HR — aborting rather than filtering everyone out."
    return
}

# Presence is not population. A field can exist on every record and be blank on
# most of them — it passes the "does this field exist" check and then fails every
# comparison. Report what was actually seen so the filter's decision is auditable
# rather than a number you have to take on trust.
Write-Output "Values seen for '$eligField':"
$workers | Group-Object $eligField | Sort-Object Count -Descending | ForEach-Object {
    $v = if ($_.Name) { $_.Name } else { '(blank)' }
    Write-Output ("    {0,-24} {1}" -f $v, $_.Count)
}

$blankElig = @($workers | Where-Object { -not $_.$eligField }).Count
$blankPct  = if ($workers.Count) { [math]::Round(($blankElig / $workers.Count) * 100, 1) } else { 0 }

if ($blankElig -gt 0) {
    Write-Warning "$blankElig of $($workers.Count) worker(s) ($blankPct%) have no '$eligField' value — treated as ineligible."
}

# Blanks fail closed, which is correct. Failing closed SILENTLY is not: at scale
# it means a slice of the workforce never gets accounts and nothing says so.
if ($blankPct -gt $maxBlankEligPercent) {
    Send-Alert -Subject "HR sync — $blankPct% of workers have no '$eligField' value" `
               -Body "$blankElig of $($workers.Count) records are missing the eligibility field. They are treated as ineligible and will not be provisioned. Past $maxBlankEligPercent% this is a data-quality problem in HR, not normal attrition. Nothing was uploaded."
    Write-Error "$blankPct% of workers have no '$eligField' value (threshold $maxBlankEligPercent%) — fix the HR data before syncing."
    return
}

# ELIGIBILITY GATES CREATION, NOT LIFECYCLE.
#
# It used to filter $workers here, before the plan. That was a serious bug:
# BambooHR's standard termination sets the employment status to Terminated —
# the same field eligibility reads — so a leaver was removed before the plan
# was built, never reached the Disable branch, and kept an ENABLED account.
#
# Nobody leaves the plan any more. Eligibility is evaluated per record, and only
# matters for people with no account: it decides whether one gets CREATED.
# Anyone who already has an account is always tracked, so they can always be
# disabled.
function Test-Eligible {
    param($Worker)
    ($Worker.$eligField -in $eligStatuses) -and
    ($allowDepts.Count -eq 0 -or $Worker.department -in $allowDepts) -and
    ($Worker.department -notin $exclDepts)
}

$eligibleCount = @($workers | Where-Object { Test-Eligible $_ }).Count
Write-Output "Eligible for NEW accounts: $eligibleCount of $($workers.Count)  (all $($workers.Count) remain in scope for lifecycle)"

# Not an abort. If the rule matches nobody, new hires don't get accounts — bad,
# but stopping the run would also stop LEAVERS being disabled, which is worse.
if ($eligibleCount -eq 0) {
    Send-Alert -Subject "HR sync — eligibility rule matches nobody" `
               -Body "No worker passes the eligibility rule, so no new accounts will be created. Existing accounts are still managed — leavers will still be disabled. Check the rule against the values HR actually returns."
    Write-Warning "Eligibility rule matches nobody — no accounts will be created this run. Lifecycle continues."
}


# ------------------------------------------------------------------------------
# 2 — Read live Entra state (this replaces the snapshot file)
# ------------------------------------------------------------------------------
Connect-MgGraph -Identity -NoWelcome

$live = @{}
Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, EmployeeId, Department, JobTitle, AccountEnabled |
    Where-Object { $_.EmployeeId } |
    ForEach-Object { $live[(Get-NormalizedId $_.EmployeeId)] = $_ }

Write-Output "Read $($live.Count) directory users with an employeeId set"

# If nothing has employeeId populated, matching cannot work and every record
# would be treated as new. Fail rather than create duplicates.
if ($live.Count -eq 0) {
    Send-Alert -Subject "ALERT: HR sync — no directory users have employeeId" `
               -Body "Matching requires employeeId populated in Entra. With none set, every record would create a NEW user rather than updating. Nothing was uploaded. Seed employeeId before enabling this."
    Write-Error "No directory users have employeeId populated — aborting to avoid creating duplicates."
    return
}

# Drift detector. Reconciliation is a monthly snapshot; this runs hourly. The
# gap between them is where unreconciled people accumulate — and three out of
# 3,600 never trips a volume threshold.
$liveByEmail = @{}
$liveByName  = @{}
Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, Mail, EmployeeId |
    ForEach-Object {
        if ($_.UserPrincipalName) { $liveByEmail[$_.UserPrincipalName.ToLower()] = $_ }
        if ($_.Mail)              { $liveByEmail[$_.Mail.ToLower()]              = $_ }

        # Name index. The email fallback only catches an EXACT address match — if
        # HR's address differs at all from the directory's, the record reads as a
        # new hire and a duplicate account is created. Reconciliation matches on
        # name as a lower tier; this gives the hourly run the same safety net.
        $n = Get-NormalizedName $_.DisplayName
        if ($n) {
            if (-not $liveByName.ContainsKey($n)) { $liveByName[$n] = @() }
            $liveByName[$n] += $_
        }
    }


# ------------------------------------------------------------------------------
# 3 — Build the change plan
# ------------------------------------------------------------------------------
$plan = foreach ($w in $workers) {
    $key = Get-NormalizedId $w.id
    if (-not $key) { Write-Warning "Worker '$($w.displayName)' has no id — skipped"; continue }

    $existing = $live[$key]

    # Reset every pass. Without this, one real mismatch flags everyone after it.
    $idMismatch = $false

    # An ID match is only as good as the ID. If it has been reassigned, a perfect
    # match points at the wrong person — and syncing writes one employee's data
    # onto another's account. Verify the human, not just the number.
    if ($existing) {
        if (-not $existing.DisplayName) {
            Write-Warning "  '$($w.displayName)': directory DisplayName is empty — name verification skipped."
        }
        $hrName    = (($w.displayName -replace "[^\p{L}\s]"," ") -replace "\s+"," ").Trim().ToLower()
        $entraName = (($existing.DisplayName -replace "[^\p{L}\s]"," ") -replace "\s+"," ").Trim().ToLower()
        $hrName    = (($hrName    -split " ") | Sort-Object) -join " "
        $entraName = (($entraName -split " ") | Sort-Object) -join " "
        if ($hrName -and $entraName -and $hrName -ne $entraName) {
            $idMismatch = $true
        }
    }

    # Detect on the explicit date, not the status flag. A termination date is
    # entered when notice is given, so you know weeks ahead. Status often
    # doesn't flip until payroll closes — days after the person has left.
    # That lag is the access window you're trying to close.
    # Earliest date across every configured termination field. Take the earliest
    # so a projected date entered at notice beats a formal date entered later.
    $termDate = $null
    foreach ($f in $termDateFields) {
        if ($w.$f) {
            try {
                $d = [datetime]$w.$f
                if (-not $termDate -or $d -lt $termDate) { $termDate = $d }
            } catch { }
        }
    }

    # Any one signal is enough. The date is preferred (known at notice, before
    # payroll closes); the status values are backstops for terminations recorded
    # without a date.
    $isActive = if ($termDate -and $termDate -le (Get-Date))  { $false }
                elseif ($w.$eligField -in $terminatedStatuses) { $false }
                elseif ($w.status -eq 'Inactive')              { $false }
                else                                           { $true }

    $isEligible = Test-Eligible $w

    # The address the pipeline will actually use. HR may supply one; if not, and
    # this person needs an account, we derive it. Computing it here rather than
    # inside $change means it survives to the payload — otherwise it is generated
    # and then discarded, and the record is dropped for "no email".
    # Precedence matters, and each rule prevents a specific failure:
    #
    #  1. EXISTING ACCOUNT -> always the directory's own UPN. HR must never
    #     rename an account. If userName maps to userPrincipalName, sending
    #     HR's differing address renames the user and breaks their sign-in.
    #
    #  2. HR address on OUR domain -> use it. HR knows what it should be.
    #
    #  3. HR address on a FOREIGN domain -> ignore it. Provisioning cannot
    #     create an account on an unverified domain; the record would fail.
    #     Treat it as no address and derive one.
    #
    #  4. No usable address, no account, still employed -> generate.
    $effectiveUpn = $null

    if ($existing) {
        $effectiveUpn = $existing.UserPrincipalName
    }
    elseif ($w.workEmail -and $w.workEmail.ToLower().EndsWith("@$($ourDomain.ToLower())")) {
        $effectiveUpn = $w.workEmail
    }

    if (-not $effectiveUpn -and -not $existing -and $isActive -and $isEligible) {
        $base = New-UpnFromName -First $w.firstName -Last $w.lastName -Domain $ourDomain
        if ($base) {
            $effectiveUpn = Get-UniqueUpn -BaseUpn $base -TakenLookup $liveByEmail
            # Reserve it immediately, or two new hires in one batch both get john.smith@
            if ($effectiveUpn) { $liveByEmail[$effectiveUpn.ToLower()] = "pending" }
        }
    }

    # Order is priority. First true branch wins, so the dangerous cases go first.
    $change =
        if ($idMismatch) { 'IdMismatch' }
        elseif (-not $existing) {
            $byEmail = if ($w.workEmail) { $liveByEmail[$w.workEmail.ToLower()] } else { $null }

            # Name fallback. An exact email match is a narrow net — change one
            # character of the address in HR and a real employee reads as a new
            # hire, and provisioning creates them a second account. Only an
            # unambiguous single name match counts; two people with the same
            # name is not evidence of anything.
            $byName = $null
            if (-not $byEmail) {
                $nk = Get-NormalizedName $w.displayName
                if ($nk -and $liveByName.ContainsKey($nk)) {
                    $cands = @($liveByName[$nk])
                    if ($cands.Count -eq 1) { $byName = $cands[0] }
                }
            }

            if ($byEmail -or $byName)  { 'Unreconciled' }
            elseif (-not $isActive)     { 'Skip' }         # never provision someone who has already left
            elseif (-not $isEligible)   { 'Ineligible' }   # wrong employment type or department
            else                        { 'New' }
        }
        elseif ($existing.AccountEnabled -and -not $isActive) { 'Disable' }
        elseif (-not $existing.AccountEnabled -and $isActive) { 'Rehire' }
        elseif ($existing.Department -ne $w.department -or
                $existing.JobTitle   -ne $w.jobTitle)         { 'Update' }
        else                                                   { 'Unchanged' }

    [PSCustomObject]@{
        Key    = $key
        Name   = $w.displayName
        Change = $change
        Worker = $w
        Active = $isActive
        Upn    = $effectiveUpn
    }
}
$plan = @($plan)

$newCount     = @($plan | Where-Object Change -eq 'New').Count
$updateCount  = @($plan | Where-Object Change -eq 'Update').Count
$disableCount = @($plan | Where-Object Change -eq 'Disable').Count
$skipCount    = @($plan | Where-Object Change -eq 'Skip').Count
$inelCount    = @($plan | Where-Object Change -eq 'Ineligible').Count
$rehireCount  = @($plan | Where-Object Change -eq 'Rehire').Count
$unreconciled = @($plan | Where-Object Change -eq 'Unreconciled').Count
$idMismatches = @($plan | Where-Object Change -eq 'IdMismatch').Count
$changedTotal = $newCount + $updateCount + $disableCount

# Percentage denominator = the population the directory actually holds or will
# hold. Former employees with no account and ineligible people cannot be affected
# by a bad feed, so counting them would dilute the percentage and let a genuine
# mass event through. 3 changes out of 109 records is 2.8%; out of 8 people who
# actually have or are getting accounts, it is 37.5%.
$population = @($plan | Where-Object { $_.Change -notin @('Skip','Ineligible') }).Count

Write-Output ""
Write-Output "--- CHANGE PLAN ---"
Write-Output " New          : $newCount"
Write-Output " Updated      : $updateCount"
Write-Output " Disabled     : $disableCount"
Write-Output " Rehire       : $rehireCount"
Write-Output " Skipped      : $skipCount  (already left, no account)"
Write-Output " Ineligible   : $inelCount  (no account, not entitled to one)"
Write-Output " Unreconciled : $unreconciled"
Write-Output " ID mismatch  : $idMismatches"
Write-Output " Unchanged    : $(@($plan | Where-Object Change -eq 'Unchanged').Count)"
Write-Output "-------------------"

$generated = @($plan | Where-Object { $_.Upn -and -not $_.Worker.workEmail }).Count
if ($generated -gt 0) { Write-Output " UPNs generated: $generated" }

if ($PlanOnly) {
    $plan | Where-Object Change -ne 'Unchanged' | ForEach-Object { Write-Output "  $($_.Name) — $($_.Change)" }

    # A dry run that can't tell you whether the real run would be blocked is
    # only half a dry run. Evaluate every gate, report the verdict, alert no one.
    $wouldBlock = @()
    if ($unreconciled -gt 0) { $wouldBlock += "$unreconciled unreconciled worker(s) — would HARD STOP (not overridable)" }
    if ($idMismatches -gt 0) { $wouldBlock += "$idMismatches ID mismatch(es) — would HARD STOP (not overridable)" }
    if ($disableCount -gt $MaxDisables) { $wouldBlock += "Disables $disableCount > threshold $MaxDisables" }
    if ($changedTotal -gt $MaxChanges)  { $wouldBlock += "Total changes $changedTotal > threshold $MaxChanges" }
    $pct = if ($population) { [math]::Round(($changedTotal / $population) * 100, 1) } else { 0 }
    if ($pct -gt $MaxPercentOfWorkforce) { $wouldBlock += "$pct% of workforce > threshold $MaxPercentOfWorkforce%" }

    Write-Output ""
    if ($wouldBlock.Count -gt 0) {
        Write-Output "=== THIS RUN WOULD BE BLOCKED ==="
        $wouldBlock | ForEach-Object { Write-Output "  - $_" }
    } else {
        Write-Output "=== This run would PROCEED ==="
    }
    Write-Output "-PlanOnly: nothing uploaded, no alerts sent."
    return
}

# Integrity failures are hard stops. They sit ABOVE the volume gate deliberately,
# so -Force and a raised threshold cannot reach them. Volume can legitimately be
# high during a restructure; there is no number of people-overwritten-by-the-
# wrong-person that becomes acceptable.
if ($unreconciled -gt 0 -or $idMismatches -gt 0) {
    Send-Alert -Subject "ALERT: HR sync — identity integrity check failed" -Body @"
Unreconciled : $unreconciled  (exist by email, no employeeId link)
ID mismatch  : $idMismatches  (employeeId matches, but the name doesn't)

Either would write one person's data onto another person's account.
Nothing was uploaded. Run Reconciliation and resolve before retrying.
"@
    Write-Error "Integrity check failed — $unreconciled unreconciled, $idMismatches ID mismatch(es)."
    return
}


# ------------------------------------------------------------------------------
# 4 — The gate
# ------------------------------------------------------------------------------
$tripped = @()

if ($disableCount -gt $MaxDisables) {
    $tripped += "Disable count $disableCount exceeds threshold of $MaxDisables"
}
if ($changedTotal -gt $MaxChanges) {
    $tripped += "Total changes $changedTotal exceeds threshold of $MaxChanges"
}
$pct = if ($population) { [math]::Round(($changedTotal / $population) * 100, 1) } else { 0 }
if ($pct -gt $MaxPercentOfWorkforce) {
    $tripped += "$pct% of the workforce would change, exceeding $MaxPercentOfWorkforce%"
}

if ($tripped.Count -gt 0 -and -not $Force) {
    $reasons = ($tripped | ForEach-Object { "  - $_" }) -join "`n"

    Send-Alert -Subject "ALERT: HR sync safety gate tripped — nothing uploaded" -Body @"
SAFETY GATE TRIPPED - nothing was uploaded.

$reasons

Planned: $newCount new, $updateCount updated, $disableCount disabled, of $($workers.Count) workers.
Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

Check the BambooHR source before overriding.
"@

    Write-Error "Safety gate tripped:`n$reasons"
    return
}

if ($tripped.Count -gt 0) { Write-Warning "Gate tripped but -Force specified — proceeding." }


# ------------------------------------------------------------------------------
# 4b — Writeback: give HR the address we generated
# ------------------------------------------------------------------------------
# PLACEMENT IS THE WHOLE POINT. This sits AFTER the PlanOnly return and AFTER
# the integrity hard stop, for two reasons found in testing:
#
#   1. Before the PlanOnly return, a dry run wrote to HR while reporting
#      "nothing uploaded". A dry run must not change anything, anywhere.
#   2. Before the integrity check, it wrote the address of a MISMATCHED
#      account back to HR — making a wrong link look legitimate in both
#      systems. Writeback must only trust matches the checks have cleared.
#
# It also uses the PLAN, not the raw worker list, so only records classified
# as correct matches are eligible.
#
# Failure here WARNS rather than stops. The link between systems is employeeId,
# not email — the account works and reconciliation still matches it correctly.
# Stopping the whole sync over a cosmetic update would block movers and leavers
# for everyone else.
$needsWriteback = @($plan | Where-Object {
    $_.Change -in @('Unchanged','Update') -and
    -not $_.Worker.workEmail -and
    $live.ContainsKey($_.Key) -and
    $live[$_.Key].UserPrincipalName
})

if ($needsWriteback.Count -gt 0) {
    Write-Output "Writeback: $($needsWriteback.Count) worker(s) have an account but no address in HR"
    foreach ($item in $needsWriteback) {
        $upn = $live[$item.Key].UserPrincipalName
        try {
            Invoke-RestMethod -Method POST `
                -Uri "https://api.bamboohr.com/api/gateway.php/$subdomain/v1/employees/$($item.Worker.id)" `
                -Headers @{ Authorization = "Basic $auth"; "Content-Type" = "application/json" } `
                -Body (@{ workEmail = $upn } | ConvertTo-Json) | Out-Null
            Write-Output "  Wrote $upn back to HR for $($item.Name)"
        }
        catch {
            Write-Warning "  Writeback failed for $($item.Name): $($_.Exception.Message)"
        }
    }
}


# ------------------------------------------------------------------------------
# 5 — Convert to SCIM and upload
# ------------------------------------------------------------------------------
function ConvertTo-ScimOperation {
    param($Worker, [bool] $IsActive, [string] $Upn)

    @{
        method = "POST"
        bulkId = [guid]::NewGuid().ToString()
        path   = "/Users"
        data   = @{
            schemas = @(
                "urn:ietf:params:scim:schemas:core:2.0:User"
                "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User"
            )
            externalId  = $Worker.id
            userName    = $Upn
            active      = $IsActive
            displayName = $Worker.displayName
            name = @{
                givenName  = $Worker.firstName
                familyName = $Worker.lastName
            }
            emails = @(@{ value = $Upn; type = "work"; primary = $true })
            title  = $Worker.jobTitle
            "urn:ietf:params:scim:schemas:extension:enterprise:2.0:User" = @{
                employeeNumber = $Worker.id
                department     = $Worker.department
            }
        }
    }
}

# HARD LIMIT: 50 operations per request. Not a tuning knob — the API rejects
# anything larger.
$BATCH_SIZE = 50
$endpoint = "https://graph.microsoft.com/beta/servicePrincipals/$spId/synchronization/jobs/$jobId/bulkUpload"

$uploadable = @($plan | Where-Object {
    # Unchanged is excluded too. Re-sending every unchanged record every hour is
    # thousands of pointless operations at scale and buries real changes in the
    # provisioning logs. Drift is still caught: the plan compares against LIVE
    # directory state, so a portal edit makes the record differ and it uploads.
    $_.Change -notin @('Unreconciled','IdMismatch','Skip','Rehire','Ineligible','Unchanged') -and $_.Upn -and $_.Worker.id
})

# Belt and braces. The provisioning app's scoping filter is the real control;
# this stops a record for a protected account ever being constructed. Checks
# $_.Upn, not the HR email — a generated address needs checking too.
$uploadable = @($uploadable | Where-Object {
    $u = $_.Upn
    -not ($protectedPrefixes | Where-Object { $u -like "$_*" })
})

$skipped = $plan.Count - $uploadable.Count
$notSent = @($plan | Where-Object { $_.Change -notin @('Unchanged','Skip','Ineligible') }).Count - $uploadable.Count
if ($notSent -gt 0) {
    Write-Warning "$notSent change(s) held back — unreconciled, ID mismatch, rehire, protected prefix, or missing UPN/id"
}

$failedBatches = 0
$batchNum = 0

for ($i = 0; $i -lt $uploadable.Count; $i += $BATCH_SIZE) {
    $batchNum++
    $end   = [math]::Min($i + $BATCH_SIZE - 1, $uploadable.Count - 1)
    $batch = @($uploadable[$i..$end])

    $payload = @{
        schemas      = @("urn:ietf:params:scim:api:messages:2.0:BulkRequest")
        Operations   = @($batch | ForEach-Object { ConvertTo-ScimOperation -Worker $_.Worker -IsActive $_.Active -Upn $_.Upn })
        failOnErrors = $null
    }

    try {
        Invoke-MgGraphRequest -Method POST -Uri $endpoint `
            -Body ($payload | ConvertTo-Json -Depth 10 -Compress) `
            -ContentType "application/scim+json" | Out-Null
        Write-Output "  Batch $batchNum accepted — $($batch.Count) records"
    }
    catch {
        Write-Warning "  Batch $batchNum FAILED: $($_.Exception.Message)"
        $failedBatches++
    }

    Start-Sleep -Milliseconds 250
}

# Rehires sit OUTSIDE the batch loop. Inside it, the alert fires once per batch —
# and if nothing is uploadable, the loop never runs and the alert never fires.
# Rehires are deliberately excluded from upload, so they don't depend on it.
#
# This alerts but does NOT block: re-enabling a disabled account is a judgment
# call about one person, not a data-integrity problem affecting everyone.
$rehires = @($plan | Where-Object Change -eq 'Rehire')
if ($rehires.Count -gt 0) {
    Send-Alert -Subject "HR sync — $($rehires.Count) possible rehire(s) need review" -Body @"
These accounts are disabled in Entra, but HR now shows them as active:

$(($rehires | ForEach-Object { "  $($_.Name)" }) -join "`n")

They were NOT re-enabled automatically. Confirm each is a genuine rehire before enabling.
"@
}

Write-Output ""
Write-Output "Uploaded $($uploadable.Count) records in $batchNum batch(es). Failed batches: $failedBatches"

if ($failedBatches -gt 0) {
    Send-Alert -Subject "ALERT: HR sync — $failedBatches batch(es) failed to upload" `
               -Body "Of $batchNum batches, $failedBatches were rejected. Check the job output."
    Write-Error "$failedBatches batch(es) failed to upload."
    return
}

Write-Output "202 Accepted means RECEIVED, not processed. Provisioning-Check runs separately."
Disconnect-MgGraph | Out-Null
