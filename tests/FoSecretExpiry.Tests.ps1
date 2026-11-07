#Requires -Version 7.0
# Run from the repository folder:  Invoke-Pester ./tests

BeforeAll {
    $repo = Split-Path $PSScriptRoot -Parent
    # Stand-ins so the tests run without the Graph and Az modules installed.
    $stubs = @{
        'Get-MgApplication'      = { param([switch] $All, [string[]] $Property) }
        'Get-MgApplicationOwner' = { param([string] $ApplicationId, [switch] $All) }
        'Get-AzAccessToken'      = { param([string] $ResourceUrl) }
        'Get-MgServicePrincipal' = { param([string] $Filter, [string[]] $Property) }
    }
    foreach ($name in $stubs.Keys) {
        if (-not (Get-Command $name -ErrorAction SilentlyContinue)) {
            New-Item -Path "function:global:$name" -Value $stubs[$name] | Out-Null
        }
    }
    Import-Module (Join-Path $repo 'src/FoSecretExpiry/FoSecretExpiry.psd1') -Force
    $script:now = [datetime]::new(2026, 11, 7, 12, 0, 0, [DateTimeKind]::Utc)
}

Describe 'ConvertTo-FoEnvironmentUrl' {
    It 'keeps a clean address' {
        ConvertTo-FoEnvironmentUrl 'https://contoso.operations.dynamics.com' | Should -Be 'https://contoso.operations.dynamics.com'
    }
    It 'adds https and drops paths, query strings and slashes' {
        ConvertTo-FoEnvironmentUrl ' Contoso-UAT.sandbox.operations.dynamics.com/?cmp=USMF&mi=DefaultDashboard ' |
            Should -Be 'https://contoso-uat.sandbox.operations.dynamics.com'
    }
    It 'refuses http' {
        { ConvertTo-FoEnvironmentUrl 'http://contoso.operations.dynamics.com' } | Should -Throw '*https*'
    }
    It 'gives a short environment name' {
        Get-FoEnvironmentName 'contoso-prod.operations.dynamics.com' | Should -Be 'contoso-prod'
    }
}

Describe 'Get-ExpiryStatus' {
    It 'puts <Days> days left in <Status>' -ForEach @(
        @{ Days = -1; Status = 'Expired' }
        @{ Days = 0; Status = 'Within 30 days' }
        @{ Days = 30; Status = 'Within 30 days' }
        @{ Days = 31; Status = 'Within 60 days' }
        @{ Days = 60; Status = 'Within 60 days' }
        @{ Days = 90; Status = 'Within 90 days' }
        @{ Days = 91; Status = 'Later' }
    ) {
        $result = Get-ExpiryStatus -EndDate $now.AddDays($Days).AddMinutes(1) -StartDate $now.AddDays(-10) -Now $now
        $result.Status | Should -Be $Status
        $result.DaysLeft | Should -Be $Days
    }
    It 'flags secrets that never expire' {
        $result = Get-ExpiryStatus -EndDate ([datetime] '2299-12-31') -StartDate $now.AddDays(-10) -Now $now
        $result.NeverExpires | Should -BeTrue
        $result.DaysLeft | Should -BeNullOrEmpty
    }
    It 'treats a missing end date as never expires' {
        (Get-ExpiryStatus -EndDate $null -Now $now).NeverExpires | Should -BeTrue
    }
    It 'flags secrets valid for more than two years' {
        (Get-ExpiryStatus -EndDate $now.AddDays(400) -StartDate $now.AddDays(-400) -Now $now).LongLived | Should -BeTrue
        (Get-ExpiryStatus -EndDate $now.AddDays(300) -StartDate $now.AddDays(-400) -Now $now).LongLived | Should -BeFalse
    }
    It 'uses a custom long-lived limit' {
        (Get-ExpiryStatus -EndDate $now.AddDays(200) -StartDate $now -Now $now -LongLivedDays 180).LongLived | Should -BeTrue
    }
}

Describe 'ConvertTo-CredentialRow' {
    It 'makes one row per secret and certificate' {
        $app = [pscustomobject]@{
            AppId = 'A1'; DisplayName = 'EDI'; Owners = @('a@contoso.com', 'b@contoso.com')
            PasswordCredentials = @([pscustomobject]@{ DisplayName = 's1'; StartDateTime = $now.AddDays(-5); EndDateTime = $now.AddDays(10) })
            KeyCredentials = @([pscustomobject]@{ DisplayName = 'c1'; StartDateTime = $now.AddDays(-5); EndDateTime = $now.AddDays(-2) })
        }
        $rows = @(ConvertTo-CredentialRow -Application @($app) -Now $now)
        $rows.Count | Should -Be 2
        $rows[0].CredentialType | Should -Be 'Secret'
        $rows[0].Status | Should -Be 'Within 30 days'
        $rows[1].CredentialType | Should -Be 'Certificate'
        $rows[1].Status | Should -Be 'Expired'
        $rows[0].Owners | Should -Be 'a@contoso.com; b@contoso.com'
    }
    It 'gives an app without credentials one row' {
        $app = [pscustomobject]@{ AppId = 'A2'; DisplayName = 'Empty'; Owners = @(); PasswordCredentials = @(); KeyCredentials = @() }
        $row = ConvertTo-CredentialRow -Application @($app) -Now $now
        $row.CredentialType | Should -Be 'None'
    }
    It 'copes with credentials that have no display name' {
        $app = [pscustomobject]@{ AppId = 'A3'; DisplayName = 'X'
            PasswordCredentials = @([pscustomobject]@{ KeyId = 'key-1'; EndDateTime = $now.AddDays(5) }); KeyCredentials = @() }
        (ConvertTo-CredentialRow -Application @($app) -Now $now).CredentialName | Should -Be 'key-1'
    }
}

Describe 'Get-EntraApplication' {
    It 'reads apps and owners with read-only Graph calls' {
        Mock -ModuleName FoSecretExpiry Get-MgApplication {
            @([pscustomobject]@{ Id = 'obj1'; AppId = 'app1'; DisplayName = 'EDI'; PasswordCredentials = @(); KeyCredentials = @() })
        }
        Mock -ModuleName FoSecretExpiry Get-MgApplicationOwner {
            @([pscustomobject]@{ Id = 'u1'; AdditionalProperties = @{ userPrincipalName = 'owner@contoso.com' } })
        }
        $apps = @(Get-EntraApplication)
        $apps[0].Owners | Should -Be @('owner@contoso.com')
        Should -Invoke -ModuleName FoSecretExpiry Get-MgApplication -Times 1 -ParameterFilter { $All }
    }
    It 'carries on when owners cannot be read' {
        Mock -ModuleName FoSecretExpiry Get-MgApplication {
            @([pscustomobject]@{ Id = 'obj1'; AppId = 'app1'; DisplayName = 'EDI'; PasswordCredentials = @(); KeyCredentials = @() })
        }
        Mock -ModuleName FoSecretExpiry Get-MgApplicationOwner { throw 'Forbidden' }
        $apps = @(Get-EntraApplication)
        $apps.Count | Should -Be 1
        $apps[0].Owners.Count | Should -Be 0
    }
}

Describe 'Get-FoAadClient' {
    BeforeEach {
        Mock -ModuleName FoSecretExpiry Invoke-RestMethod {
            if ($Uri -like '*skiptoken*') {
                [pscustomobject]@{ value = @([pscustomobject]@{ AADClientId = 'BBBB'; Name = 'Second'; UserId = 'U2' }) }
            }
            else {
                [pscustomobject]@{
                    value = @([pscustomobject]@{ AADClientId = ' AAAA '; Name = 'First'; UserId = 'U1' })
                    '@odata.nextLink' = 'https://contoso.operations.dynamics.com/data/SysAADClients?$skiptoken=2'
                }
            }
        }
    }
    It 'reads every page with GET only' {
        $clients = @(Get-FoAadClient -EnvironmentUrl 'contoso.operations.dynamics.com/' -AccessToken 'token')
        $clients.Count | Should -Be 2
        $clients[0].ClientId | Should -Be 'aaaa'
        $clients[0].Environment | Should -Be 'contoso'
        $clients[1].UserId | Should -Be 'U2'
        Should -Invoke -ModuleName FoSecretExpiry Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'Get' }
        Should -Invoke -ModuleName FoSecretExpiry Invoke-RestMethod -Times 0 -ParameterFilter { $Method -ne 'Get' }
    }
    It 'asks only for the three fields it needs, with the token' {
        Get-FoAadClient -EnvironmentUrl 'https://contoso.operations.dynamics.com' -AccessToken 'token' | Out-Null
        Should -Invoke -ModuleName FoSecretExpiry Invoke-RestMethod -ParameterFilter {
            $Uri -eq 'https://contoso.operations.dynamics.com/data/SysAADClients?$select=AADClientId,Name,UserId' -and
            $Headers.Authorization -eq 'Bearer token'
        }
    }
}

Describe 'Get-FoAccessToken' {
    It 'returns plain text when Az gives a secure string' {
        Mock -ModuleName FoSecretExpiry Get-AzAccessToken { [pscustomobject]@{ Token = (ConvertTo-SecureString 'abc' -AsPlainText -Force) } }
        Get-FoAccessToken -EnvironmentUrl 'https://contoso.operations.dynamics.com' | Should -Be 'abc'
    }
    It 'returns plain text when Az gives a string' {
        Mock -ModuleName FoSecretExpiry Get-AzAccessToken { [pscustomobject]@{ Token = 'xyz' } }
        Get-FoAccessToken -EnvironmentUrl 'https://contoso.operations.dynamics.com' | Should -Be 'xyz'
    }
}

Describe 'Import-FoAadClientExport' {
    It 'reads the column names of an Excel export' {
        $path = Join-Path $TestDrive 'Prod.csv'
        @(
            '"Client ID","Name","User ID"'
            '"AAAA-1","EDI","Admin"'
            '"","blank row",""'
        ) | Set-Content $path
        $clients = @(Import-FoAadClientExport -Path $path)
        $clients.Count | Should -Be 1
        $clients[0].Environment | Should -Be 'Prod'
        $clients[0].ClientId | Should -Be 'aaaa-1'
        $clients[0].UserId | Should -Be 'Admin'
    }
    It 'explains a file without a client ID column' {
        $path = Join-Path $TestDrive 'bad.csv'
        @('"Something","Else"', '"1","2"') | Set-Content $path
        { Import-FoAadClientExport -Path $path } | Should -Throw "*Client ID*"
    }
}

Describe 'Merge-FoUsage and Select-ReportRow' {
    BeforeAll {
        $rows = @(
            [pscustomobject]@{ AppName = 'EDI'; AppId = 'AAAA'; Status = 'Later'; DaysLeft = 200; NeverExpires = $false; LongLived = $false }
            [pscustomobject]@{ AppName = 'HR'; AppId = 'bbbb'; Status = 'Within 30 days'; DaysLeft = 10; NeverExpires = $false; LongLived = $false }
            [pscustomobject]@{ AppName = 'Quiet'; AppId = 'cccc'; Status = 'Later'; DaysLeft = 300; NeverExpires = $false; LongLived = $false }
        )
        $clients = @(
            [pscustomobject]@{ Environment = 'prod'; ClientId = 'aaaa'; Name = 'EDI'; UserId = 'INT' }
            [pscustomobject]@{ Environment = 'uat'; ClientId = 'aaaa'; Name = 'EDI'; UserId = 'INT' }
            [pscustomobject]@{ Environment = 'prod'; ClientId = 'dddd'; Name = 'Vendor app'; UserId = '' }
        )
        $merged = Merge-FoUsage -Row $rows -FoClient $clients
    }
    It 'matches app IDs regardless of case and lists every environment' {
        $edi = $merged.Rows | Where-Object AppName -eq 'EDI'
        $edi.UsedByFo | Should -BeTrue
        $edi.UsedBy | Should -Be 'prod (user INT); uat (user INT)'
    }
    It 'lists F&O apps that are not in the tenant' {
        $merged.NotFoundInTenant.Count | Should -Be 1
        $merged.NotFoundInTenant[0].Name | Should -Be 'Vendor app'
    }
    It 'keeps all F&O apps first, and only other apps that need attention' {
        $report = @(Select-ReportRow -Row $merged.Rows)
        $report.AppName | Should -Be @('EDI', 'HR')
    }
    It 'keeps everything with -IncludeAll' {
        @(Select-ReportRow -Row $merged.Rows -IncludeAll).Count | Should -Be 3
    }
}

Describe 'Resolve-AppOwner' {
    BeforeAll {
        Mock -ModuleName FoSecretExpiry Get-MgServicePrincipal {
            switch -Wildcard ($Filter) {
                "*11111111-1111-1111-1111-111111111111*" { [pscustomobject]@{ AppId = '1'; DisplayName = 'FinancialReportsApp'; AppOwnerOrganizationId = 'F8CDEF31-A31E-4B4A-93E4-5F571E91255A' } }
                "*22222222-2222-2222-2222-222222222222*" { [pscustomobject]@{ AppId = '2'; DisplayName = 'Vendor WMS'; AppOwnerOrganizationId = 'aaaaaaaa-0000-0000-0000-000000000000' } }
                default { }
            }
        }
        $apps = @(
            [pscustomobject]@{ ClientId = '11111111-1111-1111-1111-111111111111'; Name = ''; UsedBy = 'prod' }
            [pscustomobject]@{ ClientId = '22222222-2222-2222-2222-222222222222'; Name = 'WMS'; UsedBy = 'prod' }
            [pscustomobject]@{ ClientId = '33333333-3333-3333-3333-333333333333'; Name = 'Old'; UsedBy = 'uat' }
            [pscustomobject]@{ ClientId = "x' or 1 eq 1"; Name = 'Bad'; UsedBy = 'uat' }
        )
        $resolved = @(Resolve-AppOwner -App $apps)
    }
    It 'recognises Microsoft services and fills in their name' {
        $resolved[0].Owner | Should -Be 'Microsoft'
        $resolved[0].Name | Should -Be 'FinancialReportsApp'
    }
    It 'marks apps owned by another tenant' {
        $resolved[1].Owner | Should -Be 'Other organisation'
        $resolved[1].Name | Should -Be 'WMS'
    }
    It 'says unknown when the app is not set up in the tenant' {
        $resolved[2].Owner | Should -Be 'Unknown'
    }
    It 'never puts a value that is not an app ID into the Graph filter' {
        $resolved[3].Owner | Should -Be 'Unknown'
        Should -Invoke -ModuleName FoSecretExpiry Get-MgServicePrincipal -Times 0 -ParameterFilter { $Filter -like '*or 1 eq 1*' }
    }
    It 'shows Microsoft services apart from vendor apps in the report' {
        $html = New-ExpiryReportHtml -Row @() -NotFoundInTenant $resolved -GeneratedAt $now
        $html | Should -Match '1 Microsoft services registered in F&amp;O \(no action needed\)'
        $vendorPart = $html.Split('Apps from other organisations')[1].Split('<h2>')[0]
        $vendorPart | Should -Match 'WMS'
        $vendorPart | Should -Not -Match 'FinancialReportsApp'
        $vendorPart | Should -Not -Match 'Old'
    }
    It 'lists apps it cannot identify apart, and warns not to remove them blindly' {
        $html = New-ExpiryReportHtml -Row @() -NotFoundInTenant $resolved -GeneratedAt $now
        $unknownPart = $html.Split('Apps not set up in this tenant')[1].Split('<details')[0]
        $unknownPart | Should -Match 'Old'
        $unknownPart | Should -Match "Don't remove any of them"
        $unknownPart | Should -Not -Match 'WMS'
        $html | Should -Not -Match 'no longer used'
    }
}

Describe 'Report output' {
    BeforeAll {
        $demo = New-DemoData -Now $now
        $rows = @(ConvertTo-CredentialRow -Application $demo.Applications -Now $now)
        $merged = Merge-FoUsage -Row $rows -FoClient $demo.FoClients
        $report = @(Select-ReportRow -Row $merged.Rows)
    }
    It 'shows the F&O section before the other apps' {
        $html = New-ExpiryReportHtml -Row $report -NotFoundInTenant $merged.NotFoundInTenant -EnvironmentStatus $demo.EnvironmentStatus -GeneratedAt $now
        $html.IndexOf('<h2>Used by F&amp;O</h2>') | Should -BeLessThan $html.IndexOf('<h2>Other apps in the tenant</h2>')
        $html | Should -Match 'Apps not set up in this tenant'
    }
    It 'encodes app names so they cannot inject HTML' {
        $evil = [pscustomobject]@{ AppName = '<script>alert(1)</script>'; AppId = 'x'; Owners = ''; UsedByFo = $true; UsedBy = 'prod'
            CredentialType = 'Secret'; CredentialName = 's'; EndDate = $now; DaysLeft = 0; Status = 'Within 30 days'; NeverExpires = $false; LongLived = $false }
        $html = New-ExpiryReportHtml -Row @($evil) -GeneratedAt $now
        $html | Should -Not -Match '<script>'
        $html | Should -Match '&lt;script&gt;'
    }
    It 'writes CSV columns in a fixed order' {
        $csv = @(ConvertTo-CsvRow -Row $report)
        $csv[0].PSObject.Properties.Name[0..3] | Should -Be @('App name', 'App ID', 'Used by F&O', 'Used by')
    }
    It 'builds a Teams message with an Adaptive Card' {
        $payload = New-TeamsWorkflowPayload -Row $report | ConvertFrom-Json
        $payload.type | Should -Be 'message'
        $payload.attachments[0].contentType | Should -Be 'application/vnd.microsoft.card.adaptive'
        ($payload.attachments[0].content.body | Where-Object type -eq 'TextBlock').text -join ' ' | Should -Match 'Contoso EDI integration'
    }
}

Describe 'Send-TeamsWorkflowMessage' {
    It 'refuses a URL that is not https' {
        { Send-TeamsWorkflowMessage -Url 'http://example.com' -Payload '{}' } | Should -Throw '*https*'
    }
    It 'posts JSON once' {
        Mock -ModuleName FoSecretExpiry Invoke-RestMethod {}
        Send-TeamsWorkflowMessage -Url 'https://example.com/workflow' -Payload '{}'
        Should -Invoke -ModuleName FoSecretExpiry Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'Post' -and $ContentType -eq 'application/json' }
    }
}

Describe 'Read-only guarantee' {
    It 'uses no write method except the Teams post' {
        $source = Get-Content (Join-Path $repo 'src/FoSecretExpiry/FoSecretExpiry.psm1') -Raw
        $writes = [regex]::Matches($source, "-Method\s+(Post|Put|Patch|Delete|Merge)")
        $writes.Count | Should -Be 1
        $teams = (Get-Command Send-TeamsWorkflowMessage).Definition
        $teams | Should -Match '-Method Post'
        foreach ($verb in 'New-Mg', 'Update-Mg', 'Remove-Mg', 'Set-Mg', 'Add-Mg') {
            $source | Should -Not -Match "$verb\w+"
        }
    }
}

Describe 'Get-FoAppSecretExpiry.ps1 -Demo' {
    It 'writes an HTML report and a CSV' {
        $out = Join-Path $TestDrive 'out'
        & (Join-Path $repo 'Get-FoAppSecretExpiry.ps1') -Demo -OutputFolder $out 6>$null
        @(Get-ChildItem $out -Filter *.html).Count | Should -Be 1
        $csv = @(Import-Csv (Get-ChildItem $out -Filter *.csv).FullName)
        ($csv | Where-Object 'Used by F&O' -eq 'Yes').Count | Should -BeGreaterThan 0
    }
    It 'only posts to Teams when a workflow URL is given' {
        $script = Get-Content (Join-Path $repo 'Get-FoAppSecretExpiry.ps1') -Raw
        $script | Should -Match 'if \(\$TeamsWorkflowUrl\) \{'
        ([regex]::Matches($script, 'Send-TeamsWorkflowMessage')).Count | Should -Be 1
    }
}
