param (
    # Optional JSON containing monitored resource definitions.
    #
    # Configuration order:
    # 1. ResourcesJson runbook parameter
    # 2. ResourceAccess-ResourcesJson Automation variable
    # 3. Default resources defined in this runbook
    #
    # Example:
    #
    # [
    #   {
    #     "ResourceName": "AVD Users",
    #     "ResourceType": "Azure Virtual Desktop",
    #     "ResourceId": "avd-users",
    #     "Enabled": true,
    #     "Groups": [
    #       "c45adaf9-36c4-4469-bd43-94398f65e27c"
    #     ]
    #   }
    # ]

    [Parameter(Mandatory = $false)]
    [string]$ResourcesJson
)

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
# Default monitored resources
# ============================================================================

# These resources are used when no ResourcesJson parameter is supplied and
# ResourceAccess-ResourcesJson does not exist or is empty.
#
# ResourceName = Friendly name displayed in the workbook
# ResourceType = Logical resource/service category
# ResourceId   = Stable identifier used by the workbook
# Enabled      = Allows collection to be enabled/disabled
# Groups       = One or more Microsoft Entra group object IDs

$defaultResources = @(
    [PSCustomObject]@{
        ResourceName = 'AVD Users'
        ResourceType = 'Azure Virtual Desktop'
        ResourceId   = 'avd-users'
        Enabled      = $true

        Groups = @(
            'c45adaf9-36c4-4469-bd43-94398f65e27c'
        )
    }

    [PSCustomObject]@{
        ResourceName = 'Staff Access'
        ResourceType = 'AllStaff'
        ResourceId   = 'allstaff-access'
        Enabled      = $true

        Groups = @(
            'e9abef49-fd9c-469d-95f8-42cab8e47b18'
        )
    }

    [PSCustomObject]@{
        ResourceName = 'Support Staff Access'
        ResourceType = 'SupportStaff'
        ResourceId   = 'supportstaff-access'
        Enabled      = $true

        Groups = @(
            '630fdc0e-ceaa-43ea-9c54-919f1ba3a387'
        )
    }
)


# ============================================================================
# Functions
# ============================================================================

function Test-NullOrWhiteSpace {
    param (
        [AllowNull()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $true
    }

    $text = [string]$Value

    if ($text.Trim().Length -eq 0) {
        return $true
    }

    return $false
}


function Get-OptionalAutomationVariable {
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    try {
        $value = Get-AutomationVariable `
            -Name $Name `
            -ErrorAction Stop

        return $value
    }
    catch {
        Write-Verbose "Optional Automation variable '$Name' was not found."
        return $null
    }
}


function ConvertTo-MonitoredResourceConfiguration {
    param (
        [Parameter(Mandatory)]
        [object[]]$InputResources
    )

    $validatedResources = @()
    $usedResourceIds = @{}

    foreach ($resource in $InputResources) {

        if ($null -eq $resource) {
            continue
        }

        $resourceName = [string]$resource.ResourceName
        $resourceType = [string]$resource.ResourceType
        $resourceId   = [string]$resource.ResourceId

        if (Test-NullOrWhiteSpace -Value $resourceName) {
            throw 'A monitored resource definition is missing ResourceName.'
        }

        if (Test-NullOrWhiteSpace -Value $resourceType) {
            throw "Resource '$resourceName' is missing ResourceType."
        }

        if (Test-NullOrWhiteSpace -Value $resourceId) {
            throw "Resource '$resourceName' is missing ResourceId."
        }

        $resourceName = $resourceName.Trim()
        $resourceType = $resourceType.Trim()
        $resourceId   = $resourceId.Trim()

        $resourceIdKey = $resourceId.ToLowerInvariant()

        if ($usedResourceIds.ContainsKey($resourceIdKey)) {
            throw (
                "Duplicate ResourceId '$resourceId' was found. " +
                'ResourceId must be unique.'
            )
        }

        $usedResourceIds[$resourceIdKey] = $true


        # --------------------------------------------------------------------
        # Enabled
        # --------------------------------------------------------------------

        # Enabled defaults to true if it is not provided.

        $enabled = $true

        if ($resource.PSObject.Properties.Name -contains 'Enabled') {

            if ($resource.Enabled -is [bool]) {
                $enabled = $resource.Enabled
            }
            else {
                $enabledText = ([string]$resource.Enabled).Trim()

                if ($enabledText -match '^(true|1|yes)$') {
                    $enabled = $true
                }
                elseif ($enabledText -match '^(false|0|no)$') {
                    $enabled = $false
                }
                else {
                    throw (
                        "Resource '$resourceName' has an invalid Enabled " +
                        "value '$enabledText'. Use true or false."
                    )
                }
            }
        }


        # --------------------------------------------------------------------
        # Groups
        # --------------------------------------------------------------------

        $groups = @(
            $resource.Groups |
                ForEach-Object {

                    if (-not (Test-NullOrWhiteSpace -Value $_)) {
                        ([string]$_).Trim()
                    }
                } |
                Select-Object -Unique
        )

        if ($groups.Count -eq 0) {
            throw (
                "Resource '$resourceName' does not contain any " +
                'Microsoft Entra group IDs.'
            )
        }

        foreach ($groupId in $groups) {

            try {
                [void][guid]$groupId
            }
            catch {
                throw (
                    "Resource '$resourceName' contains invalid " +
                    "Microsoft Entra group ID '$groupId'."
                )
            }
        }


        # --------------------------------------------------------------------
        # Add validated resource
        # --------------------------------------------------------------------

        $validatedResources += [PSCustomObject]@{
            ResourceName = $resourceName
            ResourceType = $resourceType
            ResourceId   = $resourceId
            Enabled      = $enabled
            Groups       = $groups
        }
    }

    if ($validatedResources.Count -eq 0) {
        throw 'No valid monitored resource definitions were supplied.'
    }

    return @($validatedResources)
}


function Get-MonitoredResources {
    param (
        [Parameter(Mandatory = $false)]
        [string]$ParameterJson,

        [Parameter(Mandatory)]
        [object[]]$Defaults
    )

    $resourceDefinitions = $null
    $resourceJson = $null


    # ------------------------------------------------------------------------
    # Runbook parameter
    # ------------------------------------------------------------------------

    if (-not (Test-NullOrWhiteSpace -Value $ParameterJson)) {

        Write-Verbose 'Using resources supplied through runbook parameter.'

        $resourceJson = $ParameterJson
    }


    # ------------------------------------------------------------------------
    # Automation variable
    # ------------------------------------------------------------------------

    else {

        $automationVariableJson = Get-OptionalAutomationVariable `
            -Name 'ResourceAccess-ResourcesJson'

        if (
            -not (
                Test-NullOrWhiteSpace `
                    -Value $automationVariableJson
            )
        ) {

            Write-Verbose (
                'Using resources from Automation variable ' +
                'ResourceAccess-ResourcesJson.'
            )

            $resourceJson = [string]$automationVariableJson
        }


        # --------------------------------------------------------------------
        # Defaults
        # --------------------------------------------------------------------

        else {

            Write-Verbose 'Using default resource configuration.'

            $resourceDefinitions = $Defaults
        }
    }


    # ------------------------------------------------------------------------
    # Convert JSON if required
    # ------------------------------------------------------------------------

    if ($null -eq $resourceDefinitions) {

        try {

            $resourceDefinitions = @(
                $resourceJson |
                    ConvertFrom-Json `
                        -Depth 20 `
                        -ErrorAction Stop
            )
        }
        catch {

            throw (
                'The monitored resources JSON could not be parsed. ' +
                "$($_.Exception.Message)"
            )
        }
    }


    # ------------------------------------------------------------------------
    # Validate resources
    # ------------------------------------------------------------------------

    $validatedResources = @(
        ConvertTo-MonitoredResourceConfiguration `
            -InputResources $resourceDefinitions
    )


    # ------------------------------------------------------------------------
    # Return enabled resources only
    # ------------------------------------------------------------------------

    $enabledResources = @(
        $validatedResources |
            Where-Object {
                $_.Enabled -eq $true
            }
    )

    if ($enabledResources.Count -eq 0) {
        throw 'All monitored resource definitions are disabled.'
    }


    # IMPORTANT:
    #
    # Do not use Write-Output in this function for informational messages.
    # Anything written to the success pipeline becomes part of $resources.
    #
    # The only output from this function should be the resource objects.

    return @($enabledResources)
}


function Get-ManagedIdentityToken {
    param (
        [Parameter(Mandatory)]
        [string]$Resource
    )

    Write-Verbose "Requesting managed identity token for $Resource"

    if (Test-NullOrWhiteSpace -Value $env:IDENTITY_ENDPOINT) {

        throw (
            'IDENTITY_ENDPOINT is unavailable. Confirm that the ' +
            'Automation Account system-assigned managed identity is enabled.'
        )
    }

    if (Test-NullOrWhiteSpace -Value $env:IDENTITY_HEADER) {

        throw (
            'IDENTITY_HEADER is unavailable. Confirm that the ' +
            'Automation Account system-assigned managed identity is enabled.'
        )
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

    if (Test-NullOrWhiteSpace -Value $response.access_token) {
        throw "Failed to obtain a managed identity token for $Resource."
    }

    # Do not use Write-Output in this function.
    # The token must be the only object returned.

    return [string]$response.access_token
}


function Invoke-GraphPagedRequest {
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [Parameter(Mandatory)]
        [string]$AccessToken
    )

    $results = @()
    $nextLink = $Uri

    while (-not (Test-NullOrWhiteSpace -Value $nextLink)) {

        $response = Invoke-RestMethod `
            -Method Get `
            -Uri $nextLink `
            -Headers @{
                Authorization = "Bearer $AccessToken"
            }

        if ($null -ne $response.value) {
            $results += @($response.value)
        }

        $nextLink = [string]$response.'@odata.nextLink'
    }

    return @($results)
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

        Write-Warning (
            'No Resource Access records were collected. ' +
            'Nothing will be submitted.'
        )

        return
    }

    $ingestionUri = (
        '{0}/dataCollectionRules/{1}/streams/{2}?api-version=2023-01-01' -f
        $Endpoint.TrimEnd('/'),
        $ImmutableId,
        $Stream
    )

    Write-Output ''
    Write-Output (
        "Submitting $($Records.Count) record(s) to Azure Monitor..."
    )

    $batchSize = 500

    for (
        $offset = 0
        $offset -lt $Records.Count
        $offset += $batchSize
    ) {

        $remaining = $Records.Count - $offset

        if ($remaining -lt $batchSize) {
            $currentBatchSize = $remaining
        }
        else {
            $currentBatchSize = $batchSize
        }

        $batch = @(
            $Records |
                Select-Object `
                    -Skip $offset `
                    -First $currentBatchSize
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
# Automation configuration
# ============================================================================

Write-Output 'Loading Automation configuration...'

$DcrEndpoint = Get-AutomationVariable `
    -Name 'ResourceAccess-DcrEndpoint'

$DcrImmutableId = Get-AutomationVariable `
    -Name 'ResourceAccess-DcrImmutableId'

$StreamName = Get-AutomationVariable `
    -Name 'ResourceAccess-StreamName'


if (Test-NullOrWhiteSpace -Value $DcrEndpoint) {

    throw (
        'Automation variable ResourceAccess-DcrEndpoint ' +
        'is empty or missing.'
    )
}


if (Test-NullOrWhiteSpace -Value $DcrImmutableId) {

    throw (
        'Automation variable ResourceAccess-DcrImmutableId ' +
        'is empty or missing.'
    )
}


if (Test-NullOrWhiteSpace -Value $StreamName) {

    throw (
        'Automation variable ResourceAccess-StreamName ' +
        'is empty or missing.'
    )
}


Write-Output 'Automation configuration loaded successfully.'
Write-Output "DCR Endpoint:     $DcrEndpoint"
Write-Output "DCR Immutable ID: $DcrImmutableId"
Write-Output "DCR Stream:       $StreamName"
Write-Output ''


# ============================================================================
# Load and validate monitored resources
# ============================================================================

Write-Output 'Loading monitored resource configuration...'

$resources = @(
    Get-MonitoredResources `
        -ParameterJson $ResourcesJson `
        -Defaults $defaultResources
)

Write-Output 'Monitored resource configuration loaded successfully.'
Write-Output "Enabled resources: $($resources.Count)"
Write-Output ''

foreach ($resource in $resources) {

    Write-Output (
        " - $($resource.ResourceName) " +
        "[$($resource.ResourceType)] " +
        "- $($resource.Groups.Count) group(s)"
    )
}

Write-Output ''


# ============================================================================
# Authentication
# ============================================================================

Write-Output (
    'Authenticating using the Automation Account managed identity...'
)

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

$records = @()


foreach ($resource in $resources) {

    Write-Output '--------------------------------------------------'
    Write-Output "Resource: $($resource.ResourceName)"
    Write-Output "Type:     $($resource.ResourceType)"
    Write-Output "ID:       $($resource.ResourceId)"
    Write-Output '--------------------------------------------------'


    foreach ($groupId in $resource.Groups) {

        Write-Output "Processing Entra group: $groupId"

        try {

            # =================================================================
            # Get group details
            # =================================================================

            $groupUri = (
                'https://graph.microsoft.com/v1.0/groups/{0}' +
                '?$select=id,displayName'
            ) -f $groupId

            $group = Invoke-RestMethod `
                -Method Get `
                -Uri $groupUri `
                -Headers @{
                    Authorization = "Bearer $graphToken"
                }

            Write-Output "Group: $($group.displayName)"


            # =================================================================
            # Get all effective users
            # =================================================================

            # transitiveMembers includes:
            #
            # - Direct users
            # - Users inherited through nested groups
            #
            # Sign-in activity is metadata only.
            # Users do not require sign-in activity to be included.

            $membersUri = (
                'https://graph.microsoft.com/v1.0/groups/{0}/' +
                'transitiveMembers/microsoft.graph.user?' +
                '$select=id,displayName,userPrincipalName,' +
                'accountEnabled,userType,department,jobTitle,' +
                'signInActivity'
            ) -f $groupId

            $users = @(
                Invoke-GraphPagedRequest `
                    -Uri $membersUri `
                    -AccessToken $graphToken
            )

            Write-Output "Effective users found: $($users.Count)"


            # =================================================================
            # Build ResourceAccess_CL records
            # =================================================================

            foreach ($user in $users) {

                $lastSuccessfulSignIn = $null
                $lastInteractiveSignIn = $null

                if ($null -ne $user.signInActivity) {

                    $lastSuccessfulSignIn = (
                        $user.signInActivity.lastSuccessfulSignInDateTime
                    )

                    $lastInteractiveSignIn = (
                        $user.signInActivity.lastSignInDateTime
                    )
                }


                $record = [PSCustomObject][ordered]@{

                    TimeGenerated = $collectionTime

                    ResourceName = $resource.ResourceName
                    ResourceType = $resource.ResourceType
                    ResourceId   = $resource.ResourceId

                    AccessGroupName = $group.displayName
                    AccessGroupId   = $group.id

                    UserId            = $user.id
                    UserPrincipalName = $user.userPrincipalName
                    DisplayName       = $user.displayName

                    AccountEnabled = [bool]$user.accountEnabled
                    UserType       = $user.userType
                    Department     = $user.department
                    JobTitle       = $user.jobTitle

                    LastSuccessfulSignIn  = $lastSuccessfulSignIn
                    LastInteractiveSignIn = $lastInteractiveSignIn
                }

                $records += $record
            }


            Write-Output (
                "$($group.displayName): " +
                "$($users.Count) user(s) collected."
            )

            Write-Output ''
        }
        catch {

            throw (
                "Collection failed for resource " +
                "'$($resource.ResourceName)' and Entra group " +
                "'$groupId'. $($_.Exception.Message)"
            )
        }
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
        $records |
            Where-Object {
                $_.ResourceId -eq $resource.ResourceId
            }
    ).Count

    Write-Output (
        "$($resource.ResourceName): " +
        "$resourceCount access record(s)"
    )
}


Write-Output ''
Write-Output "Total records collected: $($records.Count)"
Write-Output "Collection time:         $collectionTime"


# ============================================================================
# Submit to Azure Monitor
# ============================================================================

Send-LogsIngestionData `
    -Records @($records) `
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
