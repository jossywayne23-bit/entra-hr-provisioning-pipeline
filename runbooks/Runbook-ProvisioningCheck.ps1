<#
================================================================================
 RUNBOOK: Provisioning-Check

 Reads Entra provisioning logs after a sync and alerts if anything went wrong.

 WHY THIS IS A SEPARATE RUNBOOK

   202 Accepted means Entra RECEIVED the payload. It does not mean anything
   happened. Processing is asynchronous, and every record can fail on scoping
   or matching AFTER acceptance, with no error surfacing anywhere in the
   upload job.

   So "the upload succeeded" is never the answer to "did provisioning work".
   This runbook answers the real question.

 SCHEDULE IT 15 MINUTES AFTER HR-Sync.
   Run it immediately and you will see zero events and conclude everything
   failed, when it simply has not processed yet.
================================================================================
#>

param(
    [int] $LookbackMinutes = 60
)

$ErrorActionPreference = 'Stop'

$alertTo      = Get-AutomationVariable -Name 'AlertTo'
$gmailAddress = Get-AutomationVariable -Name 'GmailAddress'
$gmailPass    = Get-AutomationVariable -Name 'GmailAppPassword'

function Send-Alert {
    param([string] $Subject, [string] $Body)
    try {
        $secure = ConvertTo-SecureString $gmailPass -AsPlainText -Force
        $cred   = New-Object System.Management.Automation.PSCredential($gmailAddress, $secure)
        Send-MailMessage -From $gmailAddress -To $alertTo -Subject $Subject -Body $Body `
            -SmtpServer "smtp.gmail.com" -Port 587 -UseSsl -Credential $cred -WarningAction SilentlyContinue
        Write-Output "  [alert emailed to $alertTo]"
    }
    catch { Write-Warning "  Email alert failed: $($_.Exception.Message)" }
}

Connect-MgGraph -Identity -NoWelcome

$since = (Get-Date).AddMinutes(-$LookbackMinutes).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

try {
    $response = Invoke-MgGraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/auditLogs/provisioning?`$filter=activityDateTime ge $since"
}
catch {
    Write-Error "Could not read provisioning logs: $($_.Exception.Message). Confirm AuditLog.Read.All is granted to the managed identity."
    return
}

$events = @($response.value)

$parsed = $events | ForEach-Object {
    [PSCustomObject]@{
        Time   = $_.activityDateTime
        Action = $_.action
        Result = $_.provisioningStatusInfo.status
        User   = $_.targetIdentity.displayName
        Reason = $_.provisioningStatusInfo.errorInformation.reason
    }
}

$succeeded = @($parsed | Where-Object Result -eq 'success')
$failed    = @($parsed | Where-Object Result -eq 'failure')
$skipped   = @($parsed | Where-Object Result -eq 'skipped')

Write-Output "Provisioning results — last $LookbackMinutes minutes"
Write-Output "  Total     : $($parsed.Count)"
Write-Output "  Succeeded : $($succeeded.Count)"
Write-Output "  Failed    : $($failed.Count)"
Write-Output "  Skipped   : $($skipped.Count)"


# ------------------------------------------------------------------------------
# Alert conditions — three distinct problems
# ------------------------------------------------------------------------------
# Only the first is an obvious failure. The other two look like success.

$alerts = @()

# 1. Records failed. Visible in logs, but nobody reads logs at 3am.
if ($failed.Count -gt 0) {
    $detail = ($failed | Select-Object -First 5 |
        ForEach-Object { "  $($_.User) — $($_.Action): $($_.Reason)" }) -join "`n"
    $alerts += "$($failed.Count) record(s) FAILED provisioning:`n$detail"
}

# 2. Everything skipped. Not an error — usually a mis-scoped filter. Means
#    provisioning ran and did nothing at all.
if ($parsed.Count -gt 0 -and $skipped.Count -eq $parsed.Count) {
    $alerts += "ALL $($skipped.Count) record(s) were SKIPPED. Check the provisioning app's scoping filter — nothing was provisioned."
}

# 3. Nothing appeared at all. The dangerous one. The upload was accepted and
#    then vanished. No error anywhere, in either runbook.
if ($parsed.Count -eq 0) {
    $alerts += "ZERO provisioning events in the window. If HR-Sync ran and reported batches accepted, records were accepted and never processed. 202 means received, not processed."
}

if ($alerts.Count -gt 0) {
    $body = @"
Provisioning check — last $LookbackMinutes minutes

Succeeded : $($succeeded.Count)
Failed    : $($failed.Count)
Skipped   : $($skipped.Count)

$($alerts -join "`n`n")

Time: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
"@

    Send-Alert -Subject "ALERT: HR provisioning run had problems" -Body $body

    # Write-Error marks the job failed, so an Azure Monitor alert rule on job
    # failure reaches you even if SMTP is blocked from the sandbox.
    Write-Error ($alerts -join " | ")
    return
}

Write-Output "No problems detected."
Disconnect-MgGraph | Out-Null
