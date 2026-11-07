#Requires -Version 7.0
<#
    FoSecretExpiry: lists Entra app secrets and certificates that are expiring,
    and marks which Dynamics 365 F&O environments use each app.

    Everything here only reads. The one outgoing write is the optional Teams
    post (Send-TeamsWorkflowMessage), which runs only when a URL is given.
#>

Set-StrictMode -Version Latest

function Get-Value {
    # Reads a property without failing under strict mode when it is missing.
    param($Object, [string] $Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [System.Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

# --- Small helpers ---------------------------------------------------------

function ConvertTo-FoEnvironmentUrl {
    <#
    .SYNOPSIS
        Turns whatever the user pasted (with or without https://, a path or a
        query string) into the plain environment address, for example
        https://contoso.operations.dynamics.com
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory, ValueFromPipeline)][string] $Url)
    process {
        $text = $Url.Trim()
        if ($text -notmatch '^[a-z]+://') { $text = "https://$text" }
        $uri = $null
        if (-not [Uri]::TryCreate($text, [UriKind]::Absolute, [ref] $uri) -or -not $uri.Host) {
            throw "'$Url' is not a valid F&O environment address."
        }
        if ($uri.Scheme -ne 'https') { throw "'$Url' must use https." }
        "https://$($uri.Host.ToLowerInvariant())"
    }
}

function Get-FoEnvironmentName {
    <# The first part of the host name, used as a short label: contoso-prod. #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $EnvironmentUrl)
    ([Uri] (ConvertTo-FoEnvironmentUrl $EnvironmentUrl)).Host.Split('.')[0]
}

function Get-ExpiryStatus {
    <#
    .SYNOPSIS
        Works out days left, the expiry group and the two warning flags for
        one secret or certificate.
    #>
    [CmdletBinding()]
    param(
        [Nullable[datetime]] $EndDate,
        [Nullable[datetime]] $StartDate,
        [Parameter(Mandatory)][datetime] $Now,
        [int] $LongLivedDays = 730
    )
    if ($null -eq $EndDate -or $EndDate.Year -ge 2099) {
        return [pscustomobject]@{ DaysLeft = $null; Status = 'Later'; NeverExpires = $true; LongLived = $true }
    }
    $daysLeft = [int] [Math]::Floor(($EndDate.ToUniversalTime() - $Now.ToUniversalTime()).TotalDays)
    $status = if ($daysLeft -lt 0) { 'Expired' }
              elseif ($daysLeft -le 30) { 'Within 30 days' }
              elseif ($daysLeft -le 60) { 'Within 60 days' }
              elseif ($daysLeft -le 90) { 'Within 90 days' }
              else { 'Later' }
    $longLived = $false
    if ($null -ne $StartDate) {
        $longLived = ($EndDate - $StartDate).TotalDays -gt $LongLivedDays
    }
    [pscustomobject]@{ DaysLeft = $daysLeft; Status = $status; NeverExpires = $false; LongLived = $longLived }
}

# --- Reading Entra ----------------------------------------------------------

function Get-EntraApplication {
    <#
    .SYNOPSIS
        Reads every app registration with its secrets, certificates and owners.
        Needs Connect-MgGraph with Application.Read.All. Read only.
    #>
    [CmdletBinding()]
    param()
    $apps = Get-MgApplication -All -Property 'id,appId,displayName,passwordCredentials,keyCredentials' -ErrorAction Stop
    foreach ($app in $apps) {
        $owners = @()
        try {
            $owners = @(Get-MgApplicationOwner -ApplicationId $app.Id -All -ErrorAction Stop | ForEach-Object {
                $props = $_.AdditionalProperties
                if ($props -and $props['userPrincipalName']) { $props['userPrincipalName'] }
                elseif ($props -and $props['displayName']) { $props['displayName'] }
                else { $_.Id }
            })
        }
        catch {
            Write-Verbose "Could not read owners of '$($app.DisplayName)': $($_.Exception.Message)"
        }
        [pscustomobject]@{
            Id                  = $app.Id
            AppId               = $app.AppId
            DisplayName         = $app.DisplayName
            PasswordCredentials = @($app.PasswordCredentials)
            KeyCredentials      = @($app.KeyCredentials)
            Owners              = $owners
        }
    }
}

function ConvertTo-CredentialRow {
    <#
    .SYNOPSIS
        Flattens apps into one row per secret or certificate. Apps with neither
        get one row with CredentialType 'None'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Application,
        [Parameter(Mandatory)][datetime] $Now,
        [int] $LongLivedDays = 730
    )
    foreach ($app in $Application) {
        $credentials = @(
            foreach ($c in @(Get-Value $app 'PasswordCredentials')) { if ($c) { @{ Type = 'Secret'; Item = $c } } }
            foreach ($c in @(Get-Value $app 'KeyCredentials')) { if ($c) { @{ Type = 'Certificate'; Item = $c } } }
        )
        $base = [ordered]@{
            AppName = Get-Value $app 'DisplayName'
            AppId   = Get-Value $app 'AppId'
            Owners  = (@(Get-Value $app 'Owners') | Where-Object { $_ }) -join '; '
        }
        if ($credentials.Count -eq 0) {
            [pscustomobject]($base + [ordered]@{
                CredentialType = 'None'; CredentialName = ''; StartDate = $null; EndDate = $null
                DaysLeft = $null; Status = 'No secret or certificate'; NeverExpires = $false; LongLived = $false
            })
            continue
        }
        foreach ($credential in $credentials) {
            $item = $credential.Item
            $endValue = Get-Value $item 'EndDateTime'
            $startValue = Get-Value $item 'StartDateTime'
            $end = if ($endValue) { [datetime] $endValue } else { $null }
            $start = if ($startValue) { [datetime] $startValue } else { $null }
            $expiry = Get-ExpiryStatus -EndDate $end -StartDate $start -Now $Now -LongLivedDays $LongLivedDays
            $name = if (Get-Value $item 'DisplayName') { Get-Value $item 'DisplayName' } elseif (Get-Value $item 'KeyId') { "$(Get-Value $item 'KeyId')" } else { '' }
            [pscustomobject]($base + [ordered]@{
                CredentialType = $credential.Type
                CredentialName = $name
                StartDate      = $start
                EndDate        = $end
                DaysLeft       = $expiry.DaysLeft
                Status         = $expiry.Status
                NeverExpires   = $expiry.NeverExpires
                LongLived      = $expiry.LongLived
            })
        }
    }
}

# --- Reading F&O ------------------------------------------------------------

function Get-FoAccessToken {
    <#
    .SYNOPSIS
        Gets a sign-in token for one F&O environment from the current
        Az.Accounts session (Connect-AzAccount must have run first).
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $EnvironmentUrl)
    $token = (Get-AzAccessToken -ResourceUrl $EnvironmentUrl -ErrorAction Stop).Token
    if ($token -is [securestring]) {
        return [System.Net.NetworkCredential]::new('', $token).Password
    }
    $token
}

function Get-FoAadClient {
    <#
    .SYNOPSIS
        Reads the Microsoft Entra applications registered in one F&O
        environment, through the SysAADClients OData entity. GET only.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $EnvironmentUrl,
        [Parameter(Mandatory)][string] $AccessToken
    )
    $base = ConvertTo-FoEnvironmentUrl $EnvironmentUrl
    $name = Get-FoEnvironmentName $base
    $headers = @{ Authorization = "Bearer $AccessToken"; Accept = 'application/json' }
    $next = "$base/data/SysAADClients?`$select=AADClientId,Name,UserId"
    while ($next) {
        $page = Invoke-RestMethod -Method Get -Uri $next -Headers $headers -ErrorAction Stop
        foreach ($row in @(Get-Value $page 'value')) {
            if ($null -eq $row) { continue }
            [pscustomobject]@{
                Environment    = $name
                EnvironmentUrl = $base
                ClientId       = "$(Get-Value $row 'AADClientId')".Trim().ToLowerInvariant()
                Name           = Get-Value $row 'Name'
                UserId         = Get-Value $row 'UserId'
            }
        }
        $next = Get-Value $page '@odata.nextLink'
    }
}

function Import-FoAadClientExport {
    <#
    .SYNOPSIS
        Reads a CSV export of the Microsoft Entra applications form, for
        environments that can't be read live. Accepts the column names
        "Client ID" / "ClientId" / "AADClientId", "Name" and "User ID" / "UserId".
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [string] $Environment
    )
    if (-not (Test-Path -LiteralPath $Path)) { throw "File not found: $Path" }
    if (-not $Environment) { $Environment = [IO.Path]::GetFileNameWithoutExtension($Path) }
    $rows = @(Import-Csv -LiteralPath $Path)
    if ($rows.Count -eq 0) { return }
    $columns = $rows[0].PSObject.Properties.Name
    $pick = {
        param([string[]] $Candidates)
        foreach ($c in $Candidates) {
            $match = $columns | Where-Object { ($_ -replace '[\s_]', '') -ieq ($c -replace '[\s_]', '') } | Select-Object -First 1
            if ($match) { return $match }
        }
        $null
    }
    $idColumn = & $pick @('Client ID', 'AADClientId')
    if (-not $idColumn) { throw "No 'Client ID' column found in $Path. Columns: $($columns -join ', ')" }
    $nameColumn = & $pick @('Name')
    $userColumn = & $pick @('User ID', 'UserId')
    foreach ($row in $rows) {
        $id = "$($row.$idColumn)".Trim()
        if (-not $id) { continue }
        [pscustomobject]@{
            Environment    = $Environment
            EnvironmentUrl = ''
            ClientId       = $id.ToLowerInvariant()
            Name           = if ($nameColumn) { $row.$nameColumn } else { '' }
            UserId         = if ($userColumn) { $row.$userColumn } else { '' }
        }
    }
}

# --- Combining --------------------------------------------------------------

function Merge-FoUsage {
    <#
    .SYNOPSIS
        Adds "used by F&O" details to each credential row, and lists F&O
        registrations whose app isn't in this tenant.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $FoClient
    )
    $byClient = @{}
    foreach ($client in $FoClient) {
        $key = "$($client.ClientId)".ToLowerInvariant()
        if (-not $byClient.ContainsKey($key)) { $byClient[$key] = [System.Collections.Generic.List[object]]::new() }
        $byClient[$key].Add($client)
    }
    $tenantAppIds = @{}
    $rows = foreach ($r in $Row) {
        $key = "$($r.AppId)".ToLowerInvariant()
        $tenantAppIds[$key] = $true
        $uses = if ($byClient.ContainsKey($key)) { $byClient[$key] } else { @() }
        $usedBy = ($uses | ForEach-Object {
            if ($_.UserId) { "$($_.Environment) (user $($_.UserId))" } else { $_.Environment }
        } | Sort-Object -Unique) -join '; '
        $r | Select-Object *, @{ n = 'UsedByFo'; e = { [bool] $uses.Count } }, @{ n = 'UsedBy'; e = { $usedBy } }
    }
    $missing = foreach ($key in $byClient.Keys) {
        if (-not $tenantAppIds.ContainsKey($key)) {
            $first = $byClient[$key][0]
            [pscustomobject]@{
                ClientId = $key
                Name     = $first.Name
                UsedBy   = ($byClient[$key] | ForEach-Object {
                    if ($_.UserId) { "$($_.Environment) (user $($_.UserId))" } else { $_.Environment }
                } | Sort-Object -Unique) -join '; '
            }
        }
    }
    [pscustomobject]@{
        Rows           = @($rows)
        NotFoundInTenant = @($missing | Sort-Object Name)
    }
}

function Select-ReportRow {
    <#
    .SYNOPSIS
        Keeps what belongs in the report and sorts it: every credential of an
        app F&O uses, plus other apps' credentials that are expired, expire
        within 90 days, never expire or last over the long-lived limit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row,
        [switch] $IncludeAll
    )
    $kept = $Row | Where-Object {
        $IncludeAll -or $_.UsedByFo -or
        ($_.Status -in 'Expired', 'Within 30 days', 'Within 60 days', 'Within 90 days') -or
        $_.NeverExpires -or $_.LongLived
    }
    @($kept | Sort-Object `
        @{ e = { -not $_.UsedByFo } },
        @{ e = { if ($null -eq $_.DaysLeft) { [int]::MaxValue } else { $_.DaysLeft } } },
        AppName)
}

function Get-ReportSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row)
    $count = { param($filter) @($Row | Where-Object $filter).Count }
    [pscustomobject]@{
        Expired      = & $count { $_.Status -eq 'Expired' }
        Within30     = & $count { $_.Status -eq 'Within 30 days' }
        Within60     = & $count { $_.Status -eq 'Within 60 days' }
        Within90     = & $count { $_.Status -eq 'Within 90 days' }
        NeverOrLong  = & $count { $_.NeverExpires -or $_.LongLived }
        FoExpired    = & $count { $_.UsedByFo -and $_.Status -eq 'Expired' }
        FoWithin90   = & $count { $_.UsedByFo -and $_.Status -in 'Within 30 days', 'Within 60 days', 'Within 90 days' }
    }
}

# --- Output -----------------------------------------------------------------

function ConvertTo-CsvRow {
    <# The columns written to the CSV file, in a fixed order. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row)
    foreach ($r in $Row) {
        [pscustomobject][ordered]@{
            'App name'        = $r.AppName
            'App ID'          = $r.AppId
            'Used by F&O'     = if ($r.UsedByFo) { 'Yes' } else { 'No' }
            'Used by'         = $r.UsedBy
            'Type'            = $r.CredentialType
            'Secret or certificate name' = $r.CredentialName
            'Expires on'      = if ($r.EndDate) { $r.EndDate.ToString('yyyy-MM-dd') } else { '' }
            'Days left'       = $r.DaysLeft
            'Status'          = $r.Status
            'Never expires'   = if ($r.NeverExpires) { 'Yes' } else { 'No' }
            'Lasts over limit' = if ($r.LongLived) { 'Yes' } else { 'No' }
            'Owners'          = $r.Owners
        }
    }
}

function New-ExpiryReportHtml {
    <#
    .SYNOPSIS
        Builds a single self-contained HTML page. All values are HTML-encoded.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row,
        [AllowEmptyCollection()][object[]] $NotFoundInTenant = @(),
        [AllowEmptyCollection()][object[]] $EnvironmentStatus = @(),
        [Parameter(Mandatory)][datetime] $GeneratedAt,
        [string] $TenantLabel = '',
        [int] $LongLivedDays = 730
    )
    $e = { param($v) [System.Net.WebUtility]::HtmlEncode("$v") }
    $summary = Get-ReportSummary -Row $Row
    $statusClass = @{ 'Expired' = 'expired'; 'Within 30 days' = 'd30'; 'Within 60 days' = 'd60'; 'Within 90 days' = 'd90'; 'Later' = 'later'; 'No secret or certificate' = 'none' }

    $table = {
        param([object[]] $Rows, [bool] $ShowUsedBy)
        if (-not $Rows -or $Rows.Count -eq 0) { return '<p class="empty">Nothing to show.</p>' }
        $sb = [System.Text.StringBuilder]::new()
        [void] $sb.Append('<div class="scroll"><table><thead><tr><th>App</th>')
        if ($ShowUsedBy) { [void] $sb.Append('<th>Used by</th>') }
        [void] $sb.Append('<th>Secret or certificate</th><th>Expires on</th><th>Days left</th><th>Status</th><th>Owners</th></tr></thead><tbody>')
        foreach ($r in $Rows) {
            $flags = @()
            if ($r.NeverExpires) { $flags += '<span class="flag">never expires</span>' }
            elseif ($r.LongLived) { $flags += '<span class="flag">lasts over ' + [Math]::Round($LongLivedDays / 365, 1) + ' years</span>' }
            $owners = if ($r.Owners) { & $e $r.Owners } else { '<span class="warn">no owner</span>' }
            [void] $sb.Append('<tr>')
            [void] $sb.Append("<td><strong>$(& $e $r.AppName)</strong><br><span class=""muted"">$(& $e $r.AppId)</span></td>")
            if ($ShowUsedBy) { [void] $sb.Append("<td>$(& $e $r.UsedBy)</td>") }
            $credential = if ($r.CredentialType -eq 'None') { '<span class="muted">none</span>' } else { "$(& $e $r.CredentialType) <span class=""muted"">$(& $e $r.CredentialName)</span>" }
            [void] $sb.Append("<td>$credential</td>")
            [void] $sb.Append("<td class=""date"">$(if ($r.EndDate) { $r.EndDate.ToString('yyyy-MM-dd') } else { '&ndash;' })</td>")
            [void] $sb.Append("<td class=""num"">$(if ($null -ne $r.DaysLeft) { $r.DaysLeft } else { '&ndash;' })</td>")
            [void] $sb.Append("<td><span class=""pill $($statusClass[$r.Status])"">$(& $e $r.Status)</span> $($flags -join ' ')</td>")
            [void] $sb.Append("<td>$owners</td></tr>")
        }
        [void] $sb.Append('</tbody></table></div>')
        $sb.ToString()
    }

    $foRows = @($Row | Where-Object UsedByFo)
    $otherRows = @($Row | Where-Object { -not $_.UsedByFo })

    $envHtml = ($EnvironmentStatus | ForEach-Object {
        $cls = if ($_.Ok) { 'ok' } else { 'bad' }
        "<li class=""$cls""><strong>$(& $e $_.Environment)</strong> $(& $e $_.Message)</li>"
    }) -join ''
    if (-not $envHtml) { $envHtml = '<li class="bad">No F&amp;O environments were read. Every app shows under "Other apps".</li>' }

    $missingHtml = if ($NotFoundInTenant.Count -gt 0) {
        $items = ($NotFoundInTenant | ForEach-Object {
            "<tr><td><strong>$(& $e $_.Name)</strong><br><span class=""muted"">$(& $e $_.ClientId)</span></td><td>$(& $e $_.UsedBy)</td></tr>"
        }) -join ''
        @"
<h2>Registered in F&amp;O, but not found in this tenant</h2>
<p class="lead">F&amp;O trusts these apps, but they aren't app registrations in this tenant. They're often ISV or partner apps registered in the vendor's own tenant, so their secrets are the vendor's to renew. Ask the vendor when they expire, or remove the registration in F&amp;O if it's no longer used.</p>
<div class="scroll"><table><thead><tr><th>Name in F&amp;O</th><th>Used by</th></tr></thead><tbody>$items</tbody></table></div>
"@
    } else { '' }

    $card = { param($label, $value, $cls) "<div class=""card $cls""><div class=""value"">$value</div><div class=""label"">$label</div></div>" }

    @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>App secret expiry for F&amp;O</title>
<style>
:root { --bg:#f6f7f9; --panel:#fff; --text:#1d2530; --muted:#5f6b7a; --line:#dfe3e8;
  --expired:#b42318; --d30:#c4320a; --d60:#b54708; --d90:#8a6d00; --later:#2e7d32; --none:#5f6b7a; }
@media (prefers-color-scheme: dark) { :root { --bg:#14181d; --panel:#1c2229; --text:#e6e9ed; --muted:#9aa5b1; --line:#2f3944;
  --expired:#ff8a80; --d30:#ff9e66; --d60:#ffb74d; --d90:#e6c84d; --later:#81c784; --none:#9aa5b1; } }
* { box-sizing:border-box }
body { margin:0; background:var(--bg); color:var(--text); font:14px/1.5 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif }
main { max-width:1180px; margin:0 auto; padding:24px 16px 48px }
h1 { font-size:22px; margin:0 0 4px } h2 { font-size:17px; margin:32px 0 6px }
.muted { color:var(--muted); font-size:12px } .lead { color:var(--muted); margin:0 0 12px; max-width:820px }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(150px,1fr)); gap:10px; margin:18px 0 }
.card { background:var(--panel); border:1px solid var(--line); border-radius:10px; padding:12px 14px }
.card .value { font-size:26px; font-weight:650 } .card .label { color:var(--muted); font-size:12px }
.card.expired .value { color:var(--expired) } .card.d30 .value { color:var(--d30) } .card.d60 .value { color:var(--d60) } .card.d90 .value { color:var(--d90) }
ul.envs { list-style:none; padding:0; margin:8px 0 0; display:flex; flex-wrap:wrap; gap:8px }
ul.envs li { background:var(--panel); border:1px solid var(--line); border-radius:999px; padding:3px 12px; font-size:12px }
ul.envs li.ok::before { content:"\25CF "; color:var(--later) } ul.envs li.bad::before { content:"\25CF "; color:var(--expired) }
.scroll { overflow-x:auto; background:var(--panel); border:1px solid var(--line); border-radius:10px }
table { border-collapse:collapse; width:100%; min-width:760px }
th, td { text-align:left; padding:8px 10px; border-bottom:1px solid var(--line); vertical-align:top }
th { font-size:12px; color:var(--muted); font-weight:600 } tr:last-child td { border-bottom:0 }
td.num { text-align:right; font-variant-numeric:tabular-nums } td.date { white-space:nowrap }
.pill { display:inline-block; border-radius:999px; padding:1px 9px; font-size:12px; font-weight:600; border:1px solid currentColor; white-space:nowrap }
.pill.expired { color:var(--expired) } .pill.d30 { color:var(--d30) } .pill.d60 { color:var(--d60) } .pill.d90 { color:var(--d90) } .pill.later { color:var(--later) } .pill.none { color:var(--none) }
.flag { display:inline-block; font-size:11px; color:var(--muted); border:1px dashed var(--line); border-radius:6px; padding:0 6px; margin-top:2px }
.warn { color:var(--d60); font-size:12px } .empty { color:var(--muted) }
footer { margin-top:32px; color:var(--muted); font-size:12px }
</style>
</head>
<body><main>
<h1>App secrets and certificates: F&amp;O view</h1>
<div class="muted">Generated $($GeneratedAt.ToString('yyyy-MM-dd HH:mm')) $(if ($TenantLabel) { '&middot; ' + (& $e $TenantLabel) })</div>
<ul class="envs">$envHtml</ul>
<div class="cards">
$(& $card 'F&amp;O apps expired' $summary.FoExpired 'expired')
$(& $card 'F&amp;O apps expiring in 90 days' $summary.FoWithin90 'd30')
$(& $card 'All expired' $summary.Expired 'expired')
$(& $card 'All within 30 days' $summary.Within30 'd30')
$(& $card 'All within 60 days' $summary.Within60 'd60')
$(& $card 'All within 90 days' $summary.Within90 'd90')
$(& $card 'Never expire or long-lived' $summary.NeverOrLong '')
</div>

<h2>Used by F&amp;O</h2>
<p class="lead">Apps that at least one F&amp;O environment trusts (System administration &gt; Setup &gt; Microsoft Entra applications). When one of these secrets expires, the integration that uses it stops signing in to F&amp;O.</p>
$(& $table $foRows $true)

$missingHtml

<h2>Other apps in the tenant</h2>
<p class="lead">Apps no listed F&amp;O environment uses, shown only when a secret or certificate is expired, expires within 90 days, never expires, or lasts over $([Math]::Round($LongLivedDays / 365, 1)) years.</p>
$(& $table $otherRows $false)

<footer>Read-only report. Nothing was changed in Entra or F&amp;O. Contains app owner names: share it only with people who need it.</footer>
</main></body></html>
"@
}

function New-TeamsWorkflowPayload {
    <#
    .SYNOPSIS
        Builds the message for a Teams workflow ("When a Teams webhook request
        is received"): an Adaptive Card with the counts and the F&O apps that
        need attention first.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Row,
        [int] $Top = 10
    )
    $summary = Get-ReportSummary -Row $Row
    $urgent = @($Row | Where-Object { $_.UsedByFo -and $_.Status -in 'Expired', 'Within 30 days', 'Within 60 days', 'Within 90 days' } |
        Select-Object -First $Top)
    $body = [System.Collections.Generic.List[object]]::new()
    $body.Add(@{ type = 'TextBlock'; text = 'App secret expiry: F&O view'; weight = 'Bolder'; size = 'Medium'; wrap = $true })
    $body.Add(@{ type = 'FactSet'; facts = @(
        @{ title = 'F&O apps expired'; value = "$($summary.FoExpired)" }
        @{ title = 'F&O apps expiring within 90 days'; value = "$($summary.FoWithin90)" }
        @{ title = 'All apps expired'; value = "$($summary.Expired)" }
        @{ title = 'All apps within 30 days'; value = "$($summary.Within30)" }
        @{ title = 'Never expire or long-lived'; value = "$($summary.NeverOrLong)" }
    ) })
    foreach ($r in $urgent) {
        $when = if ($r.Status -eq 'Expired') { "expired $(-$r.DaysLeft) days ago" } else { "$($r.DaysLeft) days left" }
        $body.Add(@{ type = 'TextBlock'; wrap = $true; spacing = 'Small'
            text = "**$($r.AppName)**: $($r.CredentialType.ToLower()) '$($r.CredentialName)', $when. Used by $($r.UsedBy)." })
    }
    if ($urgent.Count -eq 0) {
        $body.Add(@{ type = 'TextBlock'; text = 'No F&O app secrets expire in the next 90 days.'; wrap = $true })
    }
    $message = @{
        type        = 'message'
        attachments = @(@{
            contentType = 'application/vnd.microsoft.card.adaptive'
            content     = @{
                '$schema' = 'http://adaptivecards.io/schemas/adaptive-card.json'
                type      = 'AdaptiveCard'
                version   = '1.4'
                body      = $body
            }
        })
    }
    $message | ConvertTo-Json -Depth 12
}

function Send-TeamsWorkflowMessage {
    <#
    .SYNOPSIS
        Posts the message to a Teams workflow URL. The only outgoing write in
        this tool, and only called when the user passes -TeamsWorkflowUrl.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $Url,
        [Parameter(Mandatory)][string] $Payload
    )
    if ($Url -notmatch '^https://') { throw 'The Teams workflow URL must start with https://' }
    if ($PSCmdlet.ShouldProcess('Teams workflow', 'Post summary')) {
        Invoke-RestMethod -Method Post -Uri $Url -Body $Payload -ContentType 'application/json' -ErrorAction Stop | Out-Null
    }
}

# --- Demo data --------------------------------------------------------------

function New-DemoData {
    <#
    .SYNOPSIS
        Made-up apps and F&O registrations for trying the report without a
        tenant. Dates are relative to -Now so the demo always looks current.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][datetime] $Now)
    $secret = { param($name, $startDaysAgo, $endInDays)
        [pscustomobject]@{ DisplayName = $name; KeyId = [guid]::NewGuid(); StartDateTime = $Now.AddDays(-$startDaysAgo); EndDateTime = $Now.AddDays($endInDays) } }
    $app = { param($name, $appId, $owners, $secrets, $certs)
        [pscustomobject]@{ Id = [guid]::NewGuid().ToString(); AppId = $appId; DisplayName = $name; Owners = $owners
            PasswordCredentials = @($secrets); KeyCredentials = @($certs) } }

    $apps = @(
        & $app 'Contoso EDI integration' '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0001' @('it-integration@contoso.com') @(& $secret 'prod-2025' 700 12) @()
        & $app 'Power Automate F&O flows' '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0002' @('powerplatform-admin@contoso.com') @(& $secret 'flows-secret' 360 -6) @()
        & $app 'Logic Apps order import' '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0003' @() @(& $secret 'la-order-import' 300 47) @()
        & $app 'Bank statement connector' '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0004' @('treasury-it@contoso.com') @() @(& $secret 'bank-cert-2024' 400 80)
        & $app 'Data export to warehouse' '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0005' @('data-team@contoso.com') @(& $secret 'dw-export' 30 3620) @()
        & $app 'Expense app sync' '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0006' @('finance-it@contoso.com') @(& $secret 'expense-2026' 60 300) @()
        & $app 'HR portal' '2c1d7b4f-3a8e-4d66-8f1b-6e8a2b0d0007' @('hr-it@contoso.com') @(& $secret 'hr-portal' 340 20) @()
        & $app 'Intranet search' '2c1d7b4f-3a8e-4d66-8f1b-6e8a2b0d0008' @('web-team@contoso.com') @(& $secret 'search-crawler' 700 -40) @()
        & $app 'Legacy reporting tool' '2c1d7b4f-3a8e-4d66-8f1b-6e8a2b0d0009' @() @([pscustomobject]@{ DisplayName = 'legacy'; KeyId = [guid]::NewGuid(); StartDateTime = $Now.AddDays(-1500); EndDateTime = [datetime] '2299-12-31' }) @()
        & $app 'Marketing site' '2c1d7b4f-3a8e-4d66-8f1b-6e8a2b0d0010' @('web-team@contoso.com') @(& $secret 'cms' 100 260) @()
    )
    $prod = 'contoso-prod'
    $uat = 'contoso-uat'
    $clients = @(
        [pscustomobject]@{ Environment = $prod; EnvironmentUrl = 'https://contoso-prod.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0001'; Name = 'EDI'; UserId = 'INTEGRATION' }
        [pscustomobject]@{ Environment = $uat; EnvironmentUrl = 'https://contoso-uat.sandbox.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0001'; Name = 'EDI'; UserId = 'INTEGRATION' }
        [pscustomobject]@{ Environment = $prod; EnvironmentUrl = 'https://contoso-prod.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0002'; Name = 'Power Automate'; UserId = 'PAFLOWS' }
        [pscustomobject]@{ Environment = $prod; EnvironmentUrl = 'https://contoso-prod.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0003'; Name = 'Order import'; UserId = 'INTEGRATION' }
        [pscustomobject]@{ Environment = $prod; EnvironmentUrl = 'https://contoso-prod.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0004'; Name = 'Bank'; UserId = 'BANKSVC' }
        [pscustomobject]@{ Environment = $uat; EnvironmentUrl = 'https://contoso-uat.sandbox.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0005'; Name = 'DW export'; UserId = 'DWEXPORT' }
        [pscustomobject]@{ Environment = $prod; EnvironmentUrl = 'https://contoso-prod.operations.dynamics.com'; ClientId = '1b0c6a3e-2f7d-4c55-9e0a-5d7f1a9c0006'; Name = 'Expenses'; UserId = 'EXPENSES' }
        [pscustomobject]@{ Environment = $prod; EnvironmentUrl = 'https://contoso-prod.operations.dynamics.com'; ClientId = '9f8e7d6c-0000-4000-8000-000000000a01'; Name = 'Warehouse app (vendor)'; UserId = 'WMSVENDOR' }
    )
    [pscustomobject]@{
        Applications      = $apps
        FoClients         = $clients
        EnvironmentStatus = @(
            [pscustomobject]@{ Environment = $prod; Ok = $true; Message = '7 apps registered' }
            [pscustomobject]@{ Environment = $uat; Ok = $true; Message = '2 apps registered' }
        )
    }
}

Export-ModuleMember -Function @(
    'ConvertTo-FoEnvironmentUrl', 'Get-FoEnvironmentName', 'Get-ExpiryStatus',
    'Get-EntraApplication', 'ConvertTo-CredentialRow',
    'Get-FoAccessToken', 'Get-FoAadClient', 'Import-FoAadClientExport',
    'Merge-FoUsage', 'Select-ReportRow', 'Get-ReportSummary', 'ConvertTo-CsvRow',
    'New-ExpiryReportHtml', 'New-TeamsWorkflowPayload', 'Send-TeamsWorkflowMessage',
    'New-DemoData'
)
