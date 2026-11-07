#Requires -Version 7.0
<#
.SYNOPSIS
    Lists Entra app secrets and certificates that are expired or expire soon,
    and marks which Dynamics 365 F&O environments use each app.

.DESCRIPTION
    Read only. Reads app registrations from Microsoft Graph
    (Application.Read.All) and the Microsoft Entra applications registered in
    each F&O environment (OData entity SysAADClients). Writes an HTML report
    and a CSV file to the output folder. Nothing is changed in Entra or F&O.

    Optionally posts a summary to a Teams channel through a Teams workflow URL.
    That only happens when -TeamsWorkflowUrl is given.

.PARAMETER FoEnvironmentUrl
    One or more F&O environment addresses, for example
    https://contoso-prod.operations.dynamics.com

.PARAMETER FoExportFile
    One or more CSV exports of the Microsoft Entra applications form, for
    environments that can't be read live. The file name is used as the
    environment name.

.PARAMETER TenantId
    The Entra tenant ID or domain. Recommended when you have access to
    several tenants.

.PARAMETER OutputFolder
    Where to write the HTML and CSV files. Default: ./output

.PARAMETER LongLivedDays
    Secrets or certificates valid for longer than this are flagged.
    Default: 730 (2 years).

.PARAMETER IncludeAll
    Show every app with a secret or certificate, not only those that need
    attention.

.PARAMETER TeamsWorkflowUrl
    Optional. The URL of a Teams workflow that posts to a channel. Treat it as
    a secret. Off by default.

.PARAMETER ClientId
    For unattended runs only: the app registration to sign in with.

.PARAMETER CertificateThumbprint
    For unattended runs only: the certificate of that app registration, in
    the current user's certificate store.

.PARAMETER Demo
    Use made-up data instead of signing in. Good for a first look.

.EXAMPLE
    ./Get-FoAppSecretExpiry.ps1 -Demo

.EXAMPLE
    ./Get-FoAppSecretExpiry.ps1 -TenantId contoso.onmicrosoft.com `
        -FoEnvironmentUrl https://contoso-prod.operations.dynamics.com, https://contoso-uat.sandbox.operations.dynamics.com
#>
[CmdletBinding(DefaultParameterSetName = 'Interactive')]
param(
    [string[]] $FoEnvironmentUrl = @(),
    [string[]] $FoExportFile = @(),
    [string] $TenantId,
    [string] $OutputFolder = (Join-Path (Get-Location) 'output'),
    [ValidateRange(1, 36500)][int] $LongLivedDays = 730,
    [switch] $IncludeAll,
    [string] $TeamsWorkflowUrl,

    [Parameter(ParameterSetName = 'Unattended', Mandatory)][string] $ClientId,
    [Parameter(ParameterSetName = 'Unattended', Mandatory)][string] $CertificateThumbprint,

    [Parameter(ParameterSetName = 'Demo')][switch] $Demo
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'src/FoSecretExpiry/FoSecretExpiry.psd1') -Force

$now = Get-Date
$environmentStatus = [System.Collections.Generic.List[object]]::new()
$foClients = [System.Collections.Generic.List[object]]::new()
$tenantLabel = ''

if ($Demo) {
    Write-Host 'Demo mode: using made-up data. Nothing is read from Entra or F&O.' -ForegroundColor Yellow
    $demoData = New-DemoData -Now $now
    $applications = $demoData.Applications
    $demoData.FoClients | ForEach-Object { $foClients.Add($_) }
    $demoData.EnvironmentStatus | ForEach-Object { $environmentStatus.Add($_) }
    $tenantLabel = 'Demo tenant (made-up data)'
}
else {
    if ($PSCmdlet.ParameterSetName -eq 'Unattended' -and -not $TenantId) {
        throw '-TenantId is required with -ClientId and -CertificateThumbprint.'
    }

    # --- Entra (Microsoft Graph), read only ---
    foreach ($module in 'Microsoft.Graph.Authentication', 'Microsoft.Graph.Applications') {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            throw "The $module module is missing. Install it with: Install-Module Microsoft.Graph.Applications -Scope CurrentUser"
        }
    }
    $context = Get-MgContext
    $reuse = $PSCmdlet.ParameterSetName -ne 'Unattended' -and $context -and 'Application.Read.All' -in $context.Scopes -and
        (-not $TenantId -or $context.TenantId -eq $TenantId)
    if ($reuse) {
        Write-Host 'Using the existing Microsoft Graph sign-in.'
    }
    else {
        Write-Host 'Signing in to Microsoft Graph (read only: Application.Read.All)...'
        $graphArgs = @{ NoWelcome = $true }
        if ($TenantId) { $graphArgs.TenantId = $TenantId }
        if ($PSCmdlet.ParameterSetName -eq 'Unattended') {
            $graphArgs.ClientId = $ClientId
            $graphArgs.CertificateThumbprint = $CertificateThumbprint
        }
        else {
            $graphArgs.Scopes = 'Application.Read.All'
        }
        Connect-MgGraph @graphArgs | Out-Null
        $context = Get-MgContext
    }
    $tenantLabel = "Tenant $($context.TenantId)"

    Write-Host 'Reading app registrations...'
    $applications = @(Get-EntraApplication)
    Write-Host "  $($applications.Count) app registrations found."

    # --- F&O, read only ---
    if ($FoEnvironmentUrl.Count -gt 0) {
        if (-not (Get-Module -ListAvailable -Name 'Az.Accounts')) {
            throw 'The Az.Accounts module is missing. It is used to sign in to F&O. Install it with: Install-Module Az.Accounts -Scope CurrentUser'
        }
        $azContext = Get-AzContext -ErrorAction SilentlyContinue
        if ($PSCmdlet.ParameterSetName -ne 'Unattended' -and $azContext -and (-not $TenantId -or $azContext.Tenant.Id -eq $TenantId)) {
            Write-Host 'Using the existing sign-in for F&O.'
        }
        else {
            Write-Host 'Signing in for F&O...'
            Update-AzConfig -LoginExperienceV2 Off -Scope Process -WarningAction SilentlyContinue | Out-Null
            # The macOS sign-in broker only works from an app's main thread, so use the browser instead.
            if (-not $IsWindows) { Update-AzConfig -EnableLoginByWam $false -Scope Process -WarningAction SilentlyContinue | Out-Null }
            $azArgs = @{ WarningAction = 'SilentlyContinue' }
            if ($TenantId) { $azArgs.Tenant = $TenantId }
            if ($PSCmdlet.ParameterSetName -eq 'Unattended') {
                $azArgs.ServicePrincipal = $true
                $azArgs.ApplicationId = $ClientId
                $azArgs.CertificateThumbprint = $CertificateThumbprint
            }
            Connect-AzAccount @azArgs | Out-Null
        }

        foreach ($url in $FoEnvironmentUrl) {
            $environment = $url
            try {
                $base = ConvertTo-FoEnvironmentUrl $url
                $environment = Get-FoEnvironmentName $base
                Write-Host "Reading Microsoft Entra applications in $environment..."
                $token = Get-FoAccessToken -EnvironmentUrl $base
                $clients = @(Get-FoAadClient -EnvironmentUrl $base -AccessToken $token)
                $clients | ForEach-Object { $foClients.Add($_) }
                $environmentStatus.Add([pscustomobject]@{ Environment = $environment; Ok = $true; Message = "$($clients.Count) apps registered" })
            }
            catch {
                $reason = $_.Exception.Message
                $code = $null
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { $code = [int] $_.Exception.Response.StatusCode }
                $hint = switch ($code) {
                    401 { 'Sign-in was refused. Check that you can open this environment in the browser with the same account.' }
                    403 { 'Your account can sign in but may not read this list. Ask an F&O admin, or use an export file (-FoExportFile).' }
                    404 { 'The SysAADClients entity was not found. Use an export file (-FoExportFile) for this environment.' }
                    default { 'Check the address, or use an export file (-FoExportFile).' }
                }
                Write-Warning "Could not read $environment. $hint ($reason)"
                $environmentStatus.Add([pscustomobject]@{ Environment = $environment; Ok = $false; Message = "not read: $hint" })
            }
        }
    }
}

foreach ($file in $FoExportFile) {
    $clients = @(Import-FoAadClientExport -Path $file)
    $clients | ForEach-Object { $foClients.Add($_) }
    $name = [IO.Path]::GetFileNameWithoutExtension($file)
    $environmentStatus.Add([pscustomobject]@{ Environment = $name; Ok = $true; Message = "$($clients.Count) apps (from export file)" })
}

# --- Combine and write the report ---
$rows = @(ConvertTo-CredentialRow -Application $applications -Now $now -LongLivedDays $LongLivedDays)
$merged = Merge-FoUsage -Row $rows -FoClient $foClients.ToArray()
if ($Demo) {
    $notInTenant = @($merged.NotFoundInTenant | ForEach-Object {
        [pscustomobject]@{ ClientId = $_.ClientId; Name = $_.Name; UsedBy = $_.UsedBy; Owner = $demoData.AppOwners[$_.ClientId] } })
}
else {
    $notInTenant = @(Resolve-AppOwner -App $merged.NotFoundInTenant)
}
$reportRows = @(Select-ReportRow -Row $merged.Rows -IncludeAll:$IncludeAll)

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$stamp = $now.ToString('yyyyMMdd-HHmm')
$htmlPath = Join-Path $OutputFolder "app-secret-expiry-$stamp.html"
$csvPath = Join-Path $OutputFolder "app-secret-expiry-$stamp.csv"

New-ExpiryReportHtml -Row $reportRows -NotFoundInTenant $notInTenant `
    -EnvironmentStatus $environmentStatus.ToArray() -GeneratedAt $now -TenantLabel $tenantLabel `
    -LongLivedDays $LongLivedDays | Set-Content -LiteralPath $htmlPath -Encoding utf8
ConvertTo-CsvRow -Row $reportRows | Export-Csv -LiteralPath $csvPath -NoTypeInformation -Encoding utf8

$summary = Get-ReportSummary -Row $reportRows
Write-Host ''
Write-Host "F&O apps: $($summary.FoExpired) expired, $($summary.FoWithin90) expiring within 90 days."
Write-Host "All apps: $($summary.Expired) expired, $($summary.Within30) within 30 days, $($summary.Within60) within 60, $($summary.Within90) within 90; $($summary.NeverOrLong) never expire or are long-lived."
$vendorCount = @($notInTenant | Where-Object Owner -eq 'Other organisation').Count
$microsoftCount = @($notInTenant | Where-Object Owner -eq 'Microsoft').Count
$unknownCount = $notInTenant.Count - $vendorCount - $microsoftCount
if ($vendorCount -gt 0) {
    Write-Host "$vendorCount app(s) registered in F&O belong to other organisations (often ISVs). Ask the vendor about their secrets. See the report."
}
if ($unknownCount -gt 0) {
    Write-Host "$unknownCount app(s) registered in F&O are not set up in this tenant. Many are Microsoft's own F&O services. See the report before removing any."
}
if ($microsoftCount -gt 0) {
    Write-Host "$microsoftCount Microsoft service(s) registered in F&O. Microsoft manages their secrets."
}
Write-Host "Report: $htmlPath"
Write-Host "CSV:    $csvPath"

if ($TeamsWorkflowUrl) {
    Write-Host 'Posting the summary to Teams...'
    Send-TeamsWorkflowMessage -Url $TeamsWorkflowUrl -Payload (New-TeamsWorkflowPayload -Row $reportRows)
}
