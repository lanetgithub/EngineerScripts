<#
.SYNOPSIS
Produces a read-only Entra ID user account and inactivity report.

.DESCRIPTION
Uses the Azure Automation Account managed identity and Microsoft Graph REST API
to retrieve Entra ID user details, account state, licence assignment and
successful sign-in activity.

The runbook reports:

- Total user accounts
- Enabled and disabled accounts
- Member and guest accounts
- Licensed and unlicensed accounts
- Active member accounts
- Inactive member accounts
- Member accounts that have never successfully signed in
- New member accounts
- Inactive licensed member accounts
- Optional guest activity details

This version is report-only and does not modify user accounts.

ACTIVITY CLASSIFICATION

Disabled:
    accountEnabled is false.

New:
    The account was created within the configured inactivity threshold.

Never signed in:
    Microsoft Graph returned no lastSuccessfulSignInDateTime value.

Inactive:
    The last successful sign-in occurred before the inactivity cutoff.

Active:
    The last successful sign-in occurred on or after the inactivity cutoff.

New accounts are not classified as inactive, even when no successful sign-in
activity is available.

PERMISSIONS

The Automation Account managed identity requires these Microsoft Graph
application permissions:

- User.Read.All
- AuditLog.Read.All

The tenant requires Microsoft Entra ID P1 or P2 to retrieve
lastSuccessfulSignInDateTime.

.OUTPUTS
The runbook produces:

1. Human-readable Azure Automation job output.
2. A JSON report between these markers:

   STRUCTURED-REPORT-JSON-BEGIN
   STRUCTURED-REPORT-JSON-END

The JSON report contains headline totals and detailed account collections.

.NOTES
Runbook:
    Get-EntraUserActivityReport

Runtime:
    PowerShell 7.4

Authentication:
    Azure Automation Account managed identity

Modules:
    No Microsoft Graph PowerShell modules are required.
    Az.Accounts is supplied by the standard Az Runtime Environment package.
#>

[CmdletBinding()]
param (
    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Number of days since the last successful sign-in. Default: 30'
    )]
    [ValidateRange(1, 730)]
    [int]$InactiveDays = 30,

    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Include guest activity figures and details. Default: true'
    )]
    [bool]$IncludeGuests = $true,

    [Parameter(
        Mandatory = $false,
        HelpMessage = 'Maximum detailed records written to job output. Default: 500'
    )]
    [ValidateRange(1, 5000)]
    [int]$MaximumDetailedResults = 500
)

$ErrorActionPreference = 'Stop'

$RunStartTime = Get-Date
$CurrentUtcTime = $RunStartTime.ToUniversalTime()
$CutoffDate = $CurrentUtcTime.AddDays(-$InactiveDays)

# ============================================================================
# Functions
# ============================================================================

function ConvertFrom-SecureAccessToken {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$Token
    )

    if ($Token -is [System.Security.SecureString]) {

        $Pointer = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $Token
        )

        try {
            return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR(
                $Pointer
            )
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR(
                $Pointer
            )
        }
    }

    return [string]$Token
}

function Invoke-GraphPagedRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [hashtable]$Headers
    )

    $Items = [System.Collections.Generic.List[object]]::new()
    $NextLink = $Uri
    $PageNumber = 0

    while ($NextLink) {

        $PageNumber++

        # Use Verbose rather than Output so progress text does not get added
        # to the collection returned by this function.
        Write-Verbose "Retrieving Microsoft Graph page $PageNumber."

        $Response = Invoke-RestMethod `
            -Method Get `
            -Uri $NextLink `
            -Headers $Headers `
            -ContentType 'application/json' `
            -ErrorAction Stop

        if ($Response.value) {

            foreach ($Item in $Response.value) {
                $Items.Add($Item)
            }
        }

        $NextLink = $Response.'@odata.nextLink'
    }

    return $Items
}

function Get-GraphDateTime {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $false)]
        [object]$Value
    )

    if (-not $Value) {
        return $null
    }

    try {
        return ([datetime]$Value).ToUniversalTime()
    }
    catch {
        return $null
    }
}

function Get-UserActivityStatus {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [bool]$AccountEnabled,

        [Parameter(Mandatory = $false)]
        [object]$CreatedDateTime,

        [Parameter(Mandatory = $false)]
        [object]$LastSuccessfulSignInDateTime,

        [Parameter(Mandatory)]
        [datetime]$CutoffDateTime
    )

    if (-not $AccountEnabled) {
        return 'Disabled'
    }

    if (
        $CreatedDateTime -and
        $CreatedDateTime -gt $CutoffDateTime
    ) {
        return 'New'
    }

    if (-not $LastSuccessfulSignInDateTime) {
        return 'Never signed in'
    }

    if ($LastSuccessfulSignInDateTime -lt $CutoffDateTime) {
        return 'Inactive'
    }

    return 'Active'
}

function ConvertTo-OutputUser {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [object]$User
    )

    return [ordered]@{
        Id                           = $User.Id
        DisplayName                  = $User.DisplayName
        UserPrincipalName            = $User.UserPrincipalName
        UserType                     = $User.UserType
        AccountEnabled               = $User.AccountEnabled
        Licensed                     = $User.Licensed
        AssignedLicenseCount         = $User.AssignedLicenseCount
        ActivityStatus               = $User.ActivityStatus
        CreatedDateTimeUtc           = $User.CreatedDateTime
        LastSuccessfulSignInUtc      = $User.LastSuccessfulSignInDateTime
        DaysSinceSuccessfulSignIn    = $User.DaysSinceSuccessfulSignIn
    }
}

# ============================================================================
# Run information
# ============================================================================

Write-Output ''
Write-Output '========================================================'
Write-Output 'LA NET - ENTRA USER ACTIVITY REPORT'
Write-Output '========================================================'
Write-Output "Started           : $($CurrentUtcTime.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Inactive Days     : $InactiveDays"
Write-Output "Inactivity Cutoff : $($CutoffDate.ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Include Guests    : $IncludeGuests"
Write-Output "Maximum Details   : $MaximumDetailedResults"
Write-Output 'Mode              : Report only'
Write-Output '========================================================'
Write-Output ''

# ============================================================================
# Authentication
# ============================================================================

Write-Output 'Authenticating using the Automation Account managed identity...'

Disable-AzContextAutosave -Scope Process | Out-Null

try {

    $LoginResult = Connect-AzAccount `
        -Identity `
        -ErrorAction Stop

    if (-not $LoginResult.Context) {
        throw 'Managed identity authentication returned no Azure context.'
    }

    $GraphTokenResponse = Get-AzAccessToken `
        -ResourceUrl 'https://graph.microsoft.com' `
        -ErrorAction Stop

    $GraphToken = ConvertFrom-SecureAccessToken `
        -Token $GraphTokenResponse.Token

    if (-not $GraphToken) {
        throw 'Microsoft Graph access token was empty.'
    }
}
catch {
    throw "Authentication failed: $($_.Exception.Message)"
}

$GraphHeaders = @{
    Authorization = "Bearer $GraphToken"
    Accept        = 'application/json'
}

Write-Output 'Authentication successful.'
Write-Output ''

# ============================================================================
# Microsoft Graph query
# ============================================================================

$SelectedProperties = @(
    'id'
    'displayName'
    'userPrincipalName'
    'accountEnabled'
    'userType'
    'createdDateTime'
    'assignedLicenses'
    'signInActivity'
) -join ','

$GraphUri = (
    'https://graph.microsoft.com/v1.0/users' +
    '?$select=' +
    $SelectedProperties +
    '&$top=999'
)

Write-Output 'Retrieving Entra ID users and sign-in activity...'

try {

    $Users = @(
        Invoke-GraphPagedRequest `
            -Uri $GraphUri `
            -Headers $GraphHeaders
    )
}
catch {

    $GraphError = $_.Exception.Message

    throw @"
Microsoft Graph user retrieval failed.

Error:
$GraphError

Confirm that the Automation Account managed identity has these Microsoft
Graph application permissions:

- User.Read.All
- AuditLog.Read.All

Also confirm that the tenant has Microsoft Entra ID P1 or P2 licensing
for access to lastSuccessfulSignInDateTime.
"@
}

Write-Output "Retrieved $($Users.Count) user account(s)."
Write-Output ''

# ============================================================================
# Normalise user data
# ============================================================================

$UserResults = @(
    foreach ($User in $Users) {

        $CreatedDateTime = Get-GraphDateTime `
            -Value $User.createdDateTime

        $LastSuccessfulSignInDateTime = Get-GraphDateTime `
            -Value $User.signInActivity.lastSuccessfulSignInDateTime

        $ActivityStatus = Get-UserActivityStatus `
            -AccountEnabled ([bool]$User.accountEnabled) `
            -CreatedDateTime $CreatedDateTime `
            -LastSuccessfulSignInDateTime $LastSuccessfulSignInDateTime `
            -CutoffDateTime $CutoffDate

        $DaysSinceSuccessfulSignIn = $null

        if ($LastSuccessfulSignInDateTime) {

            $SignInAge = (
                $CurrentUtcTime -
                $LastSuccessfulSignInDateTime
            )

            $DaysSinceSuccessfulSignIn = $SignInAge.Days
        }

        $AssignedLicenseCount = @(
            $User.assignedLicenses
        ).Count

        [pscustomobject]@{
            Id                           = $User.id
            DisplayName                  = $User.displayName
            UserPrincipalName            = $User.userPrincipalName
            UserType                     = $User.userType
            AccountEnabled               = [bool]$User.accountEnabled
            CreatedDateTime              = $CreatedDateTime
            LastSuccessfulSignInDateTime = $LastSuccessfulSignInDateTime
            DaysSinceSuccessfulSignIn    = $DaysSinceSuccessfulSignIn
            AssignedLicenseCount         = $AssignedLicenseCount
            Licensed                     = ($AssignedLicenseCount -gt 0)
            ActivityStatus               = $ActivityStatus
        }
    }
)

# ============================================================================
# Build account collections
# ============================================================================

$TotalUsers = $UserResults.Count

$EnabledUsers = @(
    $UserResults |
        Where-Object {
            $_.AccountEnabled
        }
)

$DisabledUsers = @(
    $UserResults |
        Where-Object {
            -not $_.AccountEnabled
        }
)

$MemberUsers = @(
    $UserResults |
        Where-Object {
            $_.UserType -eq 'Member'
        }
)

$GuestUsers = @(
    $UserResults |
        Where-Object {
            $_.UserType -eq 'Guest'
        }
)

$EnabledMemberUsers = @(
    $UserResults |
        Where-Object {
            $_.AccountEnabled -and
            $_.UserType -eq 'Member'
        }
)

$DisabledMemberUsers = @(
    $UserResults |
        Where-Object {
            -not $_.AccountEnabled -and
            $_.UserType -eq 'Member'
        }
)

$EnabledGuestUsers = @(
    $UserResults |
        Where-Object {
            $_.AccountEnabled -and
            $_.UserType -eq 'Guest'
        }
)

$DisabledGuestUsers = @(
    $UserResults |
        Where-Object {
            -not $_.AccountEnabled -and
            $_.UserType -eq 'Guest'
        }
)

$LicensedUsers = @(
    $UserResults |
        Where-Object {
            $_.Licensed
        }
)

$UnlicensedUsers = @(
    $UserResults |
        Where-Object {
            -not $_.Licensed
        }
)

$ActiveMemberUsers = @(
    $EnabledMemberUsers |
        Where-Object {
            $_.ActivityStatus -eq 'Active'
        }
)

$InactiveMemberUsers = @(
    $EnabledMemberUsers |
        Where-Object {
            $_.ActivityStatus -eq 'Inactive'
        } |
        Sort-Object LastSuccessfulSignInDateTime, DisplayName
)

$NeverSignedInMemberUsers = @(
    $EnabledMemberUsers |
        Where-Object {
            $_.ActivityStatus -eq 'Never signed in'
        } |
        Sort-Object CreatedDateTime, DisplayName
)

$NewMemberUsers = @(
    $EnabledMemberUsers |
        Where-Object {
            $_.ActivityStatus -eq 'New'
        } |
        Sort-Object CreatedDateTime, DisplayName
)

$InactiveLicensedMemberUsers = @(
    $InactiveMemberUsers |
        Where-Object {
            $_.Licensed
        }
)

$ActiveGuestUsers = @(
    $EnabledGuestUsers |
        Where-Object {
            $_.ActivityStatus -eq 'Active'
        }
)

$InactiveGuestUsers = @(
    $EnabledGuestUsers |
        Where-Object {
            $_.ActivityStatus -eq 'Inactive'
        } |
        Sort-Object LastSuccessfulSignInDateTime, DisplayName
)

$NeverSignedInGuestUsers = @(
    $EnabledGuestUsers |
        Where-Object {
            $_.ActivityStatus -eq 'Never signed in'
        } |
        Sort-Object CreatedDateTime, DisplayName
)

$NewGuestUsers = @(
    $EnabledGuestUsers |
        Where-Object {
            $_.ActivityStatus -eq 'New'
        }
)

# ============================================================================
# Tenant identity summary
# ============================================================================

Write-Output '========================================================'
Write-Output 'TENANT IDENTITY SUMMARY'
Write-Output '========================================================'
Write-Output "Total accounts                 : $TotalUsers"
Write-Output "Enabled accounts               : $($EnabledUsers.Count)"
Write-Output "Disabled accounts              : $($DisabledUsers.Count)"
Write-Output ''
Write-Output "Member accounts                : $($MemberUsers.Count)"
Write-Output "Enabled member accounts        : $($EnabledMemberUsers.Count)"
Write-Output "Disabled member accounts       : $($DisabledMemberUsers.Count)"
Write-Output ''
Write-Output "Guest accounts                 : $($GuestUsers.Count)"
Write-Output "Enabled guest accounts         : $($EnabledGuestUsers.Count)"
Write-Output "Disabled guest accounts        : $($DisabledGuestUsers.Count)"
Write-Output ''
Write-Output "Licensed accounts              : $($LicensedUsers.Count)"
Write-Output "Unlicensed accounts            : $($UnlicensedUsers.Count)"
Write-Output '========================================================'
Write-Output ''

# ============================================================================
# Member activity summary
# ============================================================================

Write-Output '========================================================'
Write-Output 'MEMBER ACCOUNT ACTIVITY'
Write-Output '========================================================'
Write-Output "Active within $InactiveDays days         : $($ActiveMemberUsers.Count)"
Write-Output "Inactive beyond $InactiveDays days       : $($InactiveMemberUsers.Count)"
Write-Output "Never successfully signed in   : $($NeverSignedInMemberUsers.Count)"
Write-Output "New within $InactiveDays days            : $($NewMemberUsers.Count)"
Write-Output "Inactive and licensed           : $($InactiveLicensedMemberUsers.Count)"
Write-Output '========================================================'
Write-Output ''

# ============================================================================
# Guest activity summary
# ============================================================================

if ($IncludeGuests) {

    Write-Output '========================================================'
    Write-Output 'GUEST ACCOUNT ACTIVITY'
    Write-Output '========================================================'
    Write-Output "Active within $InactiveDays days         : $($ActiveGuestUsers.Count)"
    Write-Output "Inactive beyond $InactiveDays days       : $($InactiveGuestUsers.Count)"
    Write-Output "Never successfully signed in   : $($NeverSignedInGuestUsers.Count)"
    Write-Output "New within $InactiveDays days            : $($NewGuestUsers.Count)"
    Write-Output '========================================================'
    Write-Output ''
}

# ============================================================================
# Inactive member details
# ============================================================================

Write-Output '========================================================'
Write-Output "INACTIVE MEMBER ACCOUNTS - OVER $InactiveDays DAYS"
Write-Output '========================================================'

if ($InactiveMemberUsers.Count -eq 0) {

    Write-Output 'No enabled member accounts matched the inactivity criteria.'
}
else {

    $InactiveMemberOutput = $InactiveMemberUsers |
        Select-Object -First $MaximumDetailedResults |
        Select-Object `
            DisplayName,
            UserPrincipalName,
            Licensed,
            LastSuccessfulSignInDateTime,
            DaysSinceSuccessfulSignIn |
        Format-Table -AutoSize |
        Out-String

    Write-Output $InactiveMemberOutput

    if ($InactiveMemberUsers.Count -gt $MaximumDetailedResults) {

        Write-Output (
            'Output limited to the first {0} of {1} inactive member accounts.' -f
            $MaximumDetailedResults,
            $InactiveMemberUsers.Count
        )
    }
}

Write-Output ''

# ============================================================================
# Never-signed-in member details
# ============================================================================

Write-Output '========================================================'
Write-Output 'ENABLED MEMBER ACCOUNTS - NEVER SUCCESSFULLY SIGNED IN'
Write-Output '========================================================'

if ($NeverSignedInMemberUsers.Count -eq 0) {

    Write-Output 'No enabled member accounts were found without successful sign-in activity.'
}
else {

    $NeverSignedInMemberOutput = $NeverSignedInMemberUsers |
        Select-Object -First $MaximumDetailedResults |
        Select-Object `
            DisplayName,
            UserPrincipalName,
            Licensed,
            CreatedDateTime |
        Format-Table -AutoSize |
        Out-String

    Write-Output $NeverSignedInMemberOutput

    if ($NeverSignedInMemberUsers.Count -gt $MaximumDetailedResults) {

        Write-Output (
            'Output limited to the first {0} of {1} never-signed-in member accounts.' -f
            $MaximumDetailedResults,
            $NeverSignedInMemberUsers.Count
        )
    }
}

Write-Output ''

# ============================================================================
# Inactive licensed member details
# ============================================================================

Write-Output '========================================================'
Write-Output 'INACTIVE LICENSED MEMBER ACCOUNTS'
Write-Output '========================================================'

if ($InactiveLicensedMemberUsers.Count -eq 0) {

    Write-Output 'No inactive enabled member accounts with assigned licences were found.'
}
else {

    $InactiveLicensedOutput = $InactiveLicensedMemberUsers |
        Select-Object -First $MaximumDetailedResults |
        Select-Object `
            DisplayName,
            UserPrincipalName,
            AssignedLicenseCount,
            LastSuccessfulSignInDateTime,
            DaysSinceSuccessfulSignIn |
        Format-Table -AutoSize |
        Out-String

    Write-Output $InactiveLicensedOutput
}

Write-Output ''

# ============================================================================
# Optional guest details
# ============================================================================

if ($IncludeGuests) {

    Write-Output '========================================================'
    Write-Output "INACTIVE GUEST ACCOUNTS - OVER $InactiveDays DAYS"
    Write-Output '========================================================'

    if ($InactiveGuestUsers.Count -eq 0) {

        Write-Output 'No enabled guest accounts matched the inactivity criteria.'
    }
    else {

        $InactiveGuestOutput = $InactiveGuestUsers |
            Select-Object -First $MaximumDetailedResults |
            Select-Object `
                DisplayName,
                UserPrincipalName,
                LastSuccessfulSignInDateTime,
                DaysSinceSuccessfulSignIn |
            Format-Table -AutoSize |
            Out-String

        Write-Output $InactiveGuestOutput

        if ($InactiveGuestUsers.Count -gt $MaximumDetailedResults) {

            Write-Output (
                'Output limited to the first {0} of {1} inactive guest accounts.' -f
                $MaximumDetailedResults,
                $InactiveGuestUsers.Count
            )
        }
    }

    Write-Output ''
}

# ============================================================================
# Final execution information
# ============================================================================

$RunEndTime = Get-Date
$RunDuration = $RunEndTime - $RunStartTime
$DurationSeconds = $RunDuration.TotalSeconds.ToString('0.0')

Write-Output '========================================================'
Write-Output 'ENTRA USER ACTIVITY REPORT COMPLETE'
Write-Output '========================================================'
Write-Output "Started                       : $($RunStartTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Completed                     : $($RunEndTime.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss')) UTC"
Write-Output "Duration                      : $DurationSeconds seconds"
Write-Output ''
Write-Output "Inactivity threshold          : $InactiveDays days"
Write-Output "Total accounts retrieved      : $TotalUsers"
Write-Output "Enabled accounts              : $($EnabledUsers.Count)"
Write-Output "Enabled member accounts       : $($EnabledMemberUsers.Count)"
Write-Output "Inactive member accounts      : $($InactiveMemberUsers.Count)"
Write-Output "Never-signed-in members       : $($NeverSignedInMemberUsers.Count)"
Write-Output "Inactive licensed members     : $($InactiveLicensedMemberUsers.Count)"

if ($IncludeGuests) {

    Write-Output "Enabled guest accounts        : $($EnabledGuestUsers.Count)"
    Write-Output "Inactive guest accounts       : $($InactiveGuestUsers.Count)"
}

Write-Output '========================================================'
Write-Output ''

# ============================================================================
# Structured report output
# ============================================================================

$StructuredInactiveMembers = @(
    foreach ($User in $InactiveMemberUsers) {
        ConvertTo-OutputUser -User $User
    }
)

$StructuredNeverSignedInMembers = @(
    foreach ($User in $NeverSignedInMemberUsers) {
        ConvertTo-OutputUser -User $User
    }
)

$StructuredInactiveLicensedMembers = @(
    foreach ($User in $InactiveLicensedMemberUsers) {
        ConvertTo-OutputUser -User $User
    }
)

$StructuredInactiveGuests = @()

if ($IncludeGuests) {

    $StructuredInactiveGuests = @(
        foreach ($User in $InactiveGuestUsers) {
            ConvertTo-OutputUser -User $User
        }
    )
}

$ReportOutput = [ordered]@{
    ReportName                   = 'Entra User Activity Report'
    GeneratedDateTimeUtc         = $RunEndTime.ToUniversalTime()
    DurationSeconds              = [decimal]$DurationSeconds
    Mode                         = 'ReportOnly'
    InactiveDays                 = $InactiveDays
    InactivityCutoffUtc          = $CutoffDate
    IncludeGuests                = $IncludeGuests

    Summary = [ordered]@{
        TotalUsers                   = $TotalUsers
        EnabledUsers                 = $EnabledUsers.Count
        DisabledUsers                = $DisabledUsers.Count

        MemberUsers                  = $MemberUsers.Count
        EnabledMemberUsers           = $EnabledMemberUsers.Count
        DisabledMemberUsers          = $DisabledMemberUsers.Count

        GuestUsers                   = $GuestUsers.Count
        EnabledGuestUsers            = $EnabledGuestUsers.Count
        DisabledGuestUsers           = $DisabledGuestUsers.Count

        LicensedUsers                = $LicensedUsers.Count
        UnlicensedUsers              = $UnlicensedUsers.Count
    }

    MemberActivity = [ordered]@{
        Active                       = $ActiveMemberUsers.Count
        Inactive                     = $InactiveMemberUsers.Count
        NeverSignedIn                = $NeverSignedInMemberUsers.Count
        New                          = $NewMemberUsers.Count
        InactiveAndLicensed          = $InactiveLicensedMemberUsers.Count
    }

    GuestActivity = [ordered]@{
        Active                       = $ActiveGuestUsers.Count
        Inactive                     = $InactiveGuestUsers.Count
        NeverSignedIn                = $NeverSignedInGuestUsers.Count
        New                          = $NewGuestUsers.Count
    }

    Details = [ordered]@{
        InactiveMembers              = $StructuredInactiveMembers
        NeverSignedInMembers         = $StructuredNeverSignedInMembers
        InactiveLicensedMembers      = $StructuredInactiveLicensedMembers
        InactiveGuests               = $StructuredInactiveGuests
    }
}

$ReportJson = $ReportOutput |
    ConvertTo-Json `
        -Depth 8 `
        -Compress

Write-Output 'STRUCTURED-REPORT-JSON-BEGIN'
Write-Output $ReportJson
Write-Output 'STRUCTURED-REPORT-JSON-END'