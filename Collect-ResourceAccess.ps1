$ErrorActionPreference = 'Stop'


# ============================================================================
# Resource Access Collector
# ============================================================================

Write-Output ''
Write-Output '=================================================='
Write-Output ' Resource Access Collection'
Write-Output '=================================================='
Write-Output "Started: $((Get-Date).ToUniversalTime().ToString('u'))"
Write-Output ''


# ============================================================================
# Automation configuration
# ============================================================================

Write-Output 'Loading Automation configuration...'

$DcrEndpoint = Get-AutomationVariable -Name 'ResourceAccess-DcrEndpoint'
$DcrImmutableId = Get-AutomationVariable -Name 'ResourceAccess-DcrImmutableId'
$StreamName = Get-AutomationVariable -Name 'ResourceAccess-StreamName'

if ([string]::IsNullOrWhiteSpace($DcrEndpoint)) {
    throw 'Automation variable ResourceAccess-DcrEndpoint is empty or missing.'
}

if ([string]::IsNullOrWhiteSpace($DcrImmutableId)) {
    throw 'Automation variable ResourceAccess-DcrImmutableId is empty or missing.'
}

if ([string]::IsNullOrWhiteSpace($StreamName)) {
    throw 'Automation variable ResourceAccess-StreamName is empty or missing.'
}

Write-Output 'Automation configuration loaded successfully.'
Write-Output "DCR Endpoint:     $DcrEndpoint"
Write-Output "DCR Immutable ID: $DcrImmutableId"
Write-Output "DCR Stream:       $StreamName"
Write-Output ''


# ============================================================================
# Monitored resources
# ============================================================================

# ResourceName must match the friendly names used by the Workbook:
#
#   AVD Users
#   Database Access
#
# One resource can contain multiple Entra access groups.
#
# transitiveMembers is used later in the script, so users inherited through
# nested groups are also included.

$resources = @(
    @{
        ResourceName = 'AVD Users'
        ResourceType = 'Azure Virtual Desktop'
        ResourceId   = 'avd-users'

        Groups = @(
            'c58225ec-5e37-45a2-826d-44edce612248'
        )
    }

    @{
        ResourceName = 'Database Access'
        ResourceType = 'Database'
        ResourceId   = 'database-access'

        Groups = @(
            '4b16864c-8d38-4c46-9dd5-e6e05bb89525',
            '879a8bcf-ee29-4f43-bccc-8eb6b9478f1a',
            '8a9d0d2a-ba4f-4b13-9b44-b60c95c9a67c',
            '830d9380-9ae2-49bd-8933-4bf320b5cf40'

        )
    }
)


# ============================================================================
# Functions
# ============================================================================

function Get-ManagedIdentityToken {
    param (
        [Parameter(Mandatory)]
        [string]$Resource
    )

    Write-Verbose "Requesting managed identity token for $Resource"

    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_ENDPOINT)) {
        throw 'IDENTITY_ENDPOINT is unavailable. Confirm that the Automation Account system-assigned managed identity is enabled.'
    }

    if ([string]::IsNullOrWhiteSpace($env:IDENTITY_HEADER)) {
        throw 'IDENTITY_HEADER is unavailable. Confirm that the Automation Account system-assigned managed identity is enabled.'
    }

    $encodedResource = [System.Uri]::EscapeDataString($Resource)

    $tokenUri = '{0}?resource={1}&api-version=2019-08-01' -f `
        $env:IDENTITY_ENDPOINT,
        $encodedResource

    $response = Invoke-RestMethod `
        -Method Get `
        -Uri $tokenUri `
        -Headers @{
            'X-IDENTITY-HEADER' = $env:IDENTITY_HEADER
            'Metadata'          = 'true'
        }

    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Failed to obtain a managed identity token for $Resource."
    }

    # Do not use Write-Output in this function.
    # The token must be the only object returned through the pipeline.
    return [string]$response.access_token
}


function Invoke-GraphPagedRequest {
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $nextLink = $Uri

    while (-not [string]::IsNullOrWhiteSpace($nextLink)) {

        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $nextLink `
            -Headers @{
                Authorization = "Bearer $AccessToken"
            }

        if ($null -ne $response.value) {
            foreach ($item in $response.value) {
                $results.Add($item)
            }
        }

        $nextLink = $response.'@odata.nextLink'
    }

    return $results.ToArray()
}


function Send-LogsIngestionData {
    param (
        [Parameter(Mandatory)]
        [object[]]$Records,

        [Parameter(Mandatory)]
        [string]$AccessToken,

        [Parameter(Mandatory)]
        [string]$Endpoint,

        [Parameter(Mandatory)]
        [string]$ImmutableId,

        [Parameter(Mandatory)]
        [string]$Stream
    )

    if ($Records.Count -eq 0) {
        Write-Warning 'No Resource Access records were collected. Nothing will be submitted.'
        return
    }

    $ingestionUri = '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f `
        $Endpoint.TrimEnd('/'),
        $ImmutableId,
        $Stream

    Write-Output ''
    Write-Output "Submitting $($Records.Count) record(s) to Azure Monitor..."

    $batchSize = 500

    for ($offset = 0; $offset -lt $Records.Count; $offset += $batchSize) {

        $remaining = $Records.Count - $offset
        $currentBatchSize = [Math]::Min($batchSize, $remaining)

        $batch = @(
            $Records |
                Select-Object -Skip $offset -First $currentBatchSize
        )

        $body = ConvertTo-Json `
            -InputObject $batch `
            -Depth 10 `
            -Compress

        Invoke-RestMethod `
            -Method Post `
            -Uri $ingestionUri `
            -Headers @{
                Authorization = "Bearer $AccessToken"
            } `
            -ContentType 'application/json' `
            -Body $body

        Write-Output "Submitted $currentBatchSize record(s)."
    }
}


# ============================================================================
# Authentication
# ============================================================================

Write-Output 'Authenticating using the Automation Account managed identity...'

$graphToken = Get-ManagedIdentityToken `
    -Resource 'https://graph.microsoft.com'

$monitorToken = Get-ManagedIdentityToken `
    -Resource 'https://monitor.azure.com'

Write-Output 'Managed identity authentication successful.'
Write-Output ''


# ============================================================================
# Collect resource access
# ============================================================================

$collectionTime = (Get-Date).ToUniversalTime().ToString('o')
$records = [System.Collections.Generic.List[object]]::new()


foreach ($resource in $resources) {

    Write-Output '--------------------------------------------------'
    Write-Output "Resource: $($resource.ResourceName)"
    Write-Output "Type:     $($resource.ResourceType)"
    Write-Output '--------------------------------------------------'

    foreach ($groupId in $resource.Groups) {

        Write-Output "Processing Entra group: $groupId"

        # --------------------------------------------------------------------
        # Get group details
        # --------------------------------------------------------------------

        $groupUri = (
            'https://graph.microsoft.com/v1.0/groups/{0}?$select=id,displayName' -f
            $groupId
        )

        $group = Invoke-RestMethod `
            -Method Get `
            -Uri $groupUri `
            -Headers @{
                Authorization = "Bearer $graphToken"
            }

        Write-Output "Group: $($group.displayName)"


        # --------------------------------------------------------------------
        # Get ALL effective users
        # --------------------------------------------------------------------

        # transitiveMembers returns:
        #
        # - Direct users
        # - Users inherited through nested groups
        #
        # Sign-in activity is additional metadata only.
        # A user does NOT need sign-in activity to be included.

        $membersUri = (
            'https://graph.microsoft.com/v1.0/groups/{0}/transitiveMembers/microsoft.graph.user?$select=id,displayName,userPrincipalName,accountEnabled,userType,department,jobTitle,signInActivity' -f
            $groupId
        )

        $users = @(
            Invoke-GraphPagedRequest `
                -Uri $membersUri `
                -AccessToken $graphToken
        )

        Write-Output "Effective users found: $($users.Count)"


        # --------------------------------------------------------------------
        # Build ResourceAccess_CL records
        # --------------------------------------------------------------------

        foreach ($user in $users) {

            $lastSuccessfulSignIn = $null
            $lastInteractiveSignIn = $null

            if ($null -ne $user.signInActivity) {
                $lastSuccessfulSignIn = $user.signInActivity.lastSuccessfulSignInDateTime
                $lastInteractiveSignIn = $user.signInActivity.lastSignInDateTime
            }

            $record = [ordered]@{
                TimeGenerated          = $collectionTime

                ResourceName           = $resource.ResourceName
                ResourceType           = $resource.ResourceType
                ResourceId             = $resource.ResourceId

                AccessGroupName        = $group.displayName
                AccessGroupId          = $group.id

            e      = $user.userPrincipalName
                DisplayName            = $user.displayName

                AccountEnabled         = [bool]$user.accountEnabled
                UserType               = $user.userType
                Department             = $user.department
                JobTitle               = $user.jobTitle

                LastSuccessfulSignIn   = $lastSuccessfulSignIn
                LastInteractiveSignIn  = $lastInteractiveSignIn
            }

            $records.Add([PSCustomObject]$record)
        }

        Write-Output "$($group.displayName): $($users.Count) user(s) collected."
        Write-Output ''
    }
}


# ============================================================================
# Collection summary
# ============================================================================

Write-Output '=================================================='
Write-Output ' Collection Summary'
Write-Output '=================================================='

foreach ($resource in $resources) {

    $resourceCount = @(
        $records | Where-Object {
            $_.ResourceId -eq $resource.ResourceId
        }
    ).Count

    Write-Output "$($resource.ResourceName): $resourceCount access record(s)"
}

Write-Output ''
Write-Output "Total records collected: $($records.Count)"
Write-Output "Collection time:         $collectionTime"


# ============================================================================
# Submit to Azure Monitor
# ============================================================================

Send-LogsIngestionData `
    -Records $records.ToArray() `
    -AccessToken $monitorToken `
    -Endpoint $DcrEndpoint `
    -ImmutableId $DcrImmutableId `
    -Stream $StreamName


# ============================================================================
# Complete
# ============================================================================

Write-Output ''
Write-Output '=================================================='
Write-Output ' Resource Access Collection Completed Successfully'
Write-Output '=================================================='
Write-Output "Completed: $((Get-Date).ToUniversalTime().ToString('u'))"