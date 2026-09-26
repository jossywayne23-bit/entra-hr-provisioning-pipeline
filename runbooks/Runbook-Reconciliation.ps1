param(
    [switch] $NoEmail
)

$ErrorActionPreference = 'Stop'

# --- Automation variables (already configured for HR-Sync) --------------------
$BambooHRApiKey    = Get-AutomationVariable -Name 'BambooHRApiKey'
$BambooHRSubdomain = Get-AutomationVariable -Name 'BambooHRSubdomain'
$alertTo           = Get-AutomationVariable -Name 'AlertTo'
$gmailAddress      = Get-AutomationVariable -Name 'GmailAddress'
$gmailPass         = Get-AutomationVariable -Name 'GmailAppPassword'

# Runbooks have no persistent filesystem. Write to the job temp directory,
# email the CSVs as attachments, and let the sandbox discard them when the job
# ends. The email IS the persistence — no storage account required.
$OutputFolder = Join-Path $env:TEMP "reconciliation"
if (-not (Test-Path $OutputFolder)) { New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null }

Connect-MgGraph -Identity -NoWelcome


# ------------------------------------------------------------------------------
# Normalisation — the thing that makes matching work across entities
# ------------------------------------------------------------------------------
function Get-NormalizedName {
    param([string] $Name)
    if (-not $Name) { return $null }
    $clean = ($Name -replace "[^\p{L}\s]", " ") -replace "\s+", " "
    $parts = $clean.Trim().ToLower() -split " " | Where-Object { $_.Length -gt 1 }
    return ($parts | Sort-Object) -join " "
}

function Get-EmailLocalPart {
    param([string] $Email)
    if (-not $Email) { return $null }
    return ($Email -split "@")[0].ToLower()
}

function Get-NormalizedId {
    param($Id)
    if ($null -eq $Id) { return $null }
    $s = $Id.ToString().Trim().ToLower()
    if ($s -match '^\d+$') { return [string][int]$s }   # strip leading zeros
    return $s
}


# ------------------------------------------------------------------------------
# 1 — Pull both sides
# ------------------------------------------------------------------------------
Write-Output "[*] Reading Entra ID directory..."

$entraUsers = @(Get-MgUser -All -Property Id, DisplayName, UserPrincipalName, Mail,
                                          EmployeeId, Department, JobTitle, AccountEnabled,
                                          UserType, CreatedDateTime, OnPremisesSyncEnabled)

Write-Output "    $($entraUsers.Count) directory accounts"

Write-Output "[*] Reading BambooHR..."

# Same custom report HR-Sync uses. Both tools MUST see the same population, or
# the people only one of them can see are invisible to every check.
$auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${BambooHRApiKey}:x"))
$uri  = "https://api.bamboohr.com/api/gateway.php/$BambooHRSubdomain/v1/reports/custom?format=JSON"
$body = @{ fields = @(
    "id", "displayName", "firstName", "lastName", "workEmail",
    "department", "jobTitle", "status", "hireDate", "terminationDate"
)} | ConvertTo-Json

$hrWorkers = @((Invoke-RestMethod -Method POST -Uri $uri -Body $body -Headers @{
    Authorization  = "Basic $auth"
    "Content-Type" = "application/json"
    Accept         = "application/json"
}).employees)

Write-Output "    $($hrWorkers.Count) HR records"

if ($hrWorkers.Count -eq 0) { throw "HR returned zero records — aborting rather than reporting everyone as orphaned." }


# ------------------------------------------------------------------------------
# 2 — Build lookup indexes
# ------------------------------------------------------------------------------
$byEmpId = @{}; $byEmail = @{}; $byNameDept = @{}; $byName = @{}

foreach ($u in $entraUsers) {
    if ($u.EmployeeId) { $byEmpId[(Get-NormalizedId $u.EmployeeId)] = $u }

    foreach ($addr in @($u.UserPrincipalName, $u.Mail)) {
        if ($addr) {
            $byEmail[$addr.ToLower()] = $u
            $lp = Get-EmailLocalPart $addr
            if ($lp -and -not $byEmail.ContainsKey("localpart:$lp")) { $byEmail["localpart:$lp"] = $u }
        }
    }

    $n = Get-NormalizedName $u.DisplayName
    if ($n) {
        if ($u.Department) {
            $k = "$n|$($u.Department.ToLower())"
            if (-not $byNameDept.ContainsKey($k)) { $byNameDept[$k] = @() }
            $byNameDept[$k] += $u
        }
        if (-not $byName.ContainsKey($n)) { $byName[$n] = @() }
        $byName[$n] += $u
    }
}


# ------------------------------------------------------------------------------
# 3 — HR to Entra: tiered matching
# ------------------------------------------------------------------------------
Write-Output "[*] Matching HR records to directory accounts..."

$matchedEntraIds = [System.Collections.Generic.HashSet[string]]::new()

$hrReport = foreach ($w in $hrWorkers) {

    $match = $null; $tier = $null; $note = ""

    # Tier 1 — employeeId already populated and matching
    $hrId = Get-NormalizedId $w.id
    if ($hrId -and $byEmpId.ContainsKey($hrId)) {
        $match = $byEmpId[$hrId]
        $tier  = "1 - employeeId"
        $note  = "Already reconciled. No action."

        # Trust the ID, but verify the human. A reassigned employeeId matches
        # perfectly while pointing at a different person.
        $hrName    = Get-NormalizedName $w.displayName
        $entraName = Get-NormalizedName $match.DisplayName
        if ($hrName -and $entraName -and $hrName -ne $entraName) {
            $tier = "0 - ID MISMATCH"
            $note = "employeeId '$($w.id)' matches, but HR says '$($w.displayName)' and the directory says '$($match.DisplayName)'. The ID may have been reassigned. DO NOT SYNC."
        }
    }

    # Tier 0 — CONFLICT. Email points at an account whose employeeId is set to
    # something ELSE. Two systems disagreeing about who this person is.
    if (-not $match -and $w.workEmail -and $byEmail.ContainsKey($w.workEmail.ToLower())) {
        $cand = $byEmail[$w.workEmail.ToLower()]
        if ($cand.EmployeeId -and (Get-NormalizedId $cand.EmployeeId) -ne $hrId) {
            $match = $cand
            $tier  = "0 - CONFLICT"
            $note  = "Email matches but Entra employeeId is '$($cand.EmployeeId)' while HR says '$($w.id)'. DO NOT SYNC until resolved."
        }
    }

    # Tier 2 — exact email match on UPN or mail
    if (-not $match -and $w.workEmail -and $byEmail.ContainsKey($w.workEmail.ToLower())) {
        $cand = $byEmail[$w.workEmail.ToLower()]
        $hrN  = Get-NormalizedName $w.displayName
        $enN  = Get-NormalizedName $cand.DisplayName
        # An email match with disagreeing names is not a link waiting to be made —
        # it is two different people sharing an address. Seeding it creates the
        # wrong link, and every sync after that looks legitimate.
        if ($hrN -and $enN -and $hrN -ne $enN) {
            $match = $cand
            $tier  = "0 - NAME MISMATCH"
            $note  = "Email matches but HR says '$($w.displayName)' and the directory says '$($cand.DisplayName)'. Seeding would link the wrong person. DO NOT SEED."
        } else {
            $match = $cand
            $tier  = "2 - email exact"
            $note  = "Safe to seed employeeId automatically."
        }
    }

    # Tier 2b — email local part matches (different domain, same person).
    # Different domains is exactly what acquisitions produce, which makes this
    # the likelier shape for a hidden conflict, not the exception.
    if (-not $match -and $w.workEmail) {
        $lp = Get-EmailLocalPart $w.workEmail
        if ($lp -and $byEmail.ContainsKey("localpart:$lp")) {
            $cand = $byEmail["localpart:$lp"]
            if ($cand.EmployeeId -and (Get-NormalizedId $cand.EmployeeId) -ne $hrId) {
                $match = $cand
                $tier  = "0 - CONFLICT"
                $note  = "Local part matches but Entra employeeId is '$($cand.EmployeeId)' while HR says '$($w.id)'. DO NOT SYNC until resolved."
            } else {
                $hrN = Get-NormalizedName $w.displayName
                $enN = Get-NormalizedName $cand.DisplayName
                if ($hrN -and $enN -and $hrN -ne $enN) {
                    $match = $cand
                    $tier  = "0 - NAME MISMATCH"
                    $note  = "Local part matches but HR says '$($w.displayName)' and the directory says '$($cand.DisplayName)'. DO NOT SEED."
                } else {
                    $match = $cand
                    $tier  = "2b - email local part"
                    $note  = "Same local part, different domain. Verify before seeding."
                }
            }
        }
    }

    # Tier 3 — normalised name plus department
    if (-not $match) {
        $n = Get-NormalizedName $w.displayName
        if ($n -and $w.department) {
            $k = "$n|$($w.department.ToLower())"
            if ($byNameDept.ContainsKey($k)) {
                $c = @($byNameDept[$k])
                if ($c.Count -eq 1) { $match = $c[0]; $tier = "3 - name + dept"; $note = "HUMAN REVIEW required." }
                else { $tier = "3x - ambiguous"; $note = "$($c.Count) accounts share this name and department. MANUAL." }
            }
        }
    }

    # Tier 4 — name only
    if (-not $match -and -not $tier) {
        $n = Get-NormalizedName $w.displayName
        if ($n -and $byName.ContainsKey($n)) {
            $c = @($byName[$n])
            if ($c.Count -eq 1) { $match = $c[0]; $tier = "4 - name only"; $note = "HIGH SCRUTINY. Confirm with HR before seeding." }
            else { $tier = "4x - ambiguous"; $note = "$($c.Count) accounts share this name. MANUAL." }
        }
    }

    if (-not $tier) { $tier = "5 - no match"; $note = "No directory account found. New hire, or no account needed." }

    if ($match) { [void]$matchedEntraIds.Add($match.Id) }

    [PSCustomObject]@{
        Tier            = $tier
        HRName          = $w.displayName
        HREmail         = $w.workEmail
        HRDepartment    = $w.department
        HRId            = $w.id
        EntraUPN        = $match.UserPrincipalName
        EntraDisplayName= $match.DisplayName
        EntraDepartment = $match.Department
        EntraEmployeeId = $match.EmployeeId
        EntraEnabled    = $match.AccountEnabled
        Action          = $note
    }
}


# ------------------------------------------------------------------------------
# 3b — COLLISIONS: two HR records matched to the SAME directory account
# ------------------------------------------------------------------------------
$collisions = $hrReport | Where-Object { $_.EntraUPN } |
    Group-Object EntraUPN | Where-Object { $_.Count -gt 1 }

foreach ($c in $collisions) {
    foreach ($row in $c.Group) {
        $row.Tier   = "0 - COLLISION"
        $row.Action = "$($c.Count) HR records resolve to this same account. Syncing would overwrite one with the other. MANUAL."
    }
}


# ------------------------------------------------------------------------------
# 4 — Entra to HR: the orphans. This is the security half.
# ------------------------------------------------------------------------------
Write-Output "[*] Finding directory accounts with no HR record..."

$orphans = foreach ($u in $entraUsers) {
    if ($matchedEntraIds.Contains($u.Id)) { continue }

    # Classify, never exclude. Reconciliation is read-only, so privileged accounts
    # appear here deliberately — that is how you confirm they still exist and that
    # nobody has quietly added one. What they must not do is look like findings.
    # An account excluded from your audit is an account you have stopped watching.
    $category =
        if ($u.UserPrincipalName -like 'bg-*')              { "Break glass — expected, verify config" }
        elseif ($u.UserPrincipalName -like 'svc-*')          { "Service account — expected, verify owner" }
        elseif ($u.UserPrincipalName -like 'admin-*')        { "Admin account — expected, verify owner" }
        elseif ($u.UserType -eq 'Guest')                     { "Guest / external" }
        elseif (-not $u.AccountEnabled)                      { "Already disabled" }
        elseif ($u.OnPremisesSyncEnabled)                    { "Synced from on-prem AD" }
        elseif (-not $u.Mail -and -not $u.Department)        { "Likely service or shared account" }
        else                                                 { "ENABLED, NO HR RECORD - investigate" }

    [PSCustomObject]@{
        Category     = $category
        DisplayName  = $u.DisplayName
        UPN          = $u.UserPrincipalName
        Department   = $u.Department
        Enabled      = $u.AccountEnabled
        UserType     = $u.UserType
        EmployeeId   = $u.EmployeeId
        Created      = $u.CreatedDateTime
    }
}
$orphans = @($orphans)


# ------------------------------------------------------------------------------
# 5 — Output
# ------------------------------------------------------------------------------
$stamp = Get-Date -Format 'yyyy-MM-dd_HHmm'
$hrPath      = Join-Path $OutputFolder "hr-to-entra-$stamp.csv"
$orphanPath  = Join-Path $OutputFolder "entra-orphans-$stamp.csv"
$seedPath    = Join-Path $OutputFolder "safe-to-seed-$stamp.csv"

$hrReport  | Sort-Object Tier | Export-Csv $hrPath     -NoTypeInformation
$orphans   | Sort-Object Category | Export-Csv $orphanPath -NoTypeInformation

# Tier 2 only, and never anything flagged as a conflict, collision or mismatch.
$safeToSeed = @($hrReport | Where-Object { $_.Tier -like "2 - *" -and $_.EntraUPN })
if ($safeToSeed.Count -gt 0) {
    $safeToSeed | Select-Object HRName, EntraUPN, HRId | Export-Csv $seedPath -NoTypeInformation
} else {
    # Always produce the artefact. An empty file with headers proves the check
    # ran; a missing file is indistinguishable from a check that never happened.
    "HRName,EntraUPN,HRId" | Set-Content $seedPath
}

$blockers = @($hrReport | Where-Object { $_.Tier -like "0 - *" })

Write-Output ""
Write-Output "============================================="
Write-Output " Reconciliation Summary"
Write-Output "============================================="
Write-Output " HR records        : $($hrWorkers.Count)"
Write-Output " Entra accounts    : $($entraUsers.Count)"
Write-Output ""
$hrReport | Group-Object Tier | Sort-Object Name | ForEach-Object {
    Write-Output ("  {0,-24} {1}" -f $_.Name, $_.Count)
}
Write-Output ""
if ($blockers.Count -gt 0) {
    Write-Output " BLOCKERS          : $($blockers.Count)  <-- resolve before ANY sync"
    $blockers | ForEach-Object { Write-Output "    $($_.Tier)  $($_.HRName)" }
    Write-Output ""
}
Write-Output " Safe to seed now  : $($safeToSeed.Count)"
Write-Output " Need human review : $(@($hrReport | Where-Object { $_.Tier -like '3*' -or $_.Tier -like '4*' }).Count)"
Write-Output " No match          : $(@($hrReport | Where-Object { $_.Tier -like '5*' }).Count)"
Write-Output ""
Write-Output " Directory orphans : $($orphans.Count)"
$orphans | Group-Object Category | Sort-Object Count -Descending | ForEach-Object {
    Write-Output ("  {0,-42} {1}" -f $_.Name, $_.Count)
}
Write-Output "============================================="
Write-Output ""
Write-Output "Reports written to $OutputFolder"
Write-Output ""
Write-Output "NEXT: review the Tier 3/4 rows with HR before seeding anything."
Write-Output "      Never auto-seed on a name match — two people called John Williams"
Write-Output "      and you have merged two identities permanently."


# ------------------------------------------------------------------------------
# Email the reports as attachments
# ------------------------------------------------------------------------------
if (-not $NoEmail) {
    $attachments = @($hrPath, $orphanPath, $seedPath) | Where-Object { Test-Path $_ }

    $subject = if ($blockers.Count -gt 0) {
        "RECONCILIATION: $($blockers.Count) BLOCKER(S) — do not sync"
    } else {
        "Reconciliation report — $($safeToSeed.Count) safe to seed"
    }

    $summary = @"
Reconciliation run $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')

HR records     : $($hrWorkers.Count)
Entra accounts : $($entraUsers.Count)

BLOCKERS (resolve before any sync) : $($blockers.Count)
$(($blockers | ForEach-Object { "  $($_.Tier)  $($_.HRName)" }) -join "`n")

Safe to seed   : $($safeToSeed.Count)
Orphans        : $($orphans.Count)

Three CSVs attached: full match report, orphan list, safe-to-seed list.
"@

    try {
        $secure = ConvertTo-SecureString $gmailPass -AsPlainText -Force
        $cred   = New-Object System.Management.Automation.PSCredential($gmailAddress, $secure)
        Send-MailMessage -From $gmailAddress -To $alertTo -Subject $subject -Body $summary `
            -Attachments $attachments -SmtpServer "smtp.gmail.com" -Port 587 -UseSsl `
            -Credential $cred -WarningAction SilentlyContinue
        Write-Output "  [report emailed to $alertTo with $($attachments.Count) attachment(s)]"
    }
    catch {
        Write-Warning "  Report email failed: $($_.Exception.Message)"
    }
}

# Set the sync block flag for HR-Sync to read
Set-AutomationVariable -Name 'SyncBlocked' -Value ($blockers.Count -gt 0)
$reason = if ($blockers.Count -gt 0) { "$($blockers.Count) blocker(s) as of $(Get-Date -Format 'yyyy-MM-dd HH:mm')" } else { "" }
Set-AutomationVariable -Name 'SyncBlockedReason' -Value $reason

# Blockers should fail the JOB, so an Azure Monitor rule on job failure catches
# them even if the email does not arrive.
if ($blockers.Count -gt 0) {
    Write-Error "$($blockers.Count) blocker(s) found — resolve before enabling sync."
}

Disconnect-MgGraph | Out-Null
