# Weekly Teams summary and unattended runs

Both are optional. By default the script runs only when you start it, signs in
as you, and sends nothing anywhere.

<!-- REVIEW: Nurlin to try both on a test tenant and update screen names. -->

## Post a summary to a Teams channel

The script can post a short summary (counts, plus the F&O apps that expire
within 90 days) to a channel through a Teams workflow.

### Create the workflow

1. In Teams, open the channel, choose **...** > **Workflows**.
2. Pick the template **Post to a channel when a webhook request is received**.
3. Finish the wizard and copy the URL it gives you.

### Keep the URL secret

Anyone with the URL can post to the channel. Don't put it in the script, a
scheduled task's command line or a shared file. Store it in a secret store, for
example with the SecretManagement module:

```powershell
Install-Module Microsoft.PowerShell.SecretManagement, Microsoft.PowerShell.SecretStore -Scope CurrentUser
Register-SecretVault -Name LocalStore -ModuleName Microsoft.PowerShell.SecretStore
Set-Secret -Name FoSecretExpiryTeamsUrl -Secret '<paste the URL>'
```

Then run:

```powershell
./Get-FoAppSecretExpiry.ps1 -TenantId contoso.onmicrosoft.com `
    -FoEnvironmentUrl https://contoso-prod.operations.dynamics.com `
    -TeamsWorkflowUrl (Get-Secret FoSecretExpiryTeamsUrl -AsPlainText)
```

## Run it every week without signing in

A scheduled run can't open a browser to sign in, so it signs in as an app with
a certificate. This needs some one-off setup by an admin. The script itself
still only reads.

1. **Create an app registration** for the report, for example
   "F&O secret expiry report".
2. **Give it the Microsoft Graph application permission `Application.Read.All`**
   and grant admin consent. This lets it read app registrations, nothing more.
3. **Add a certificate** to the app registration, and install the certificate
   with its private key in the certificate store of the account that runs the
   schedule.
4. **Register the app in each F&O environment** (System administration > Setup
   > Microsoft Entra applications) and link it to an F&O user that can read
   that list and nothing else that matters. Agree this with the F&O security
   owner first: it gives the app read access to F&O.
5. **Schedule the script**, for example in Windows Task Scheduler or an Azure
   Automation runbook:

```powershell
pwsh -File ./Get-FoAppSecretExpiry.ps1 -TenantId contoso.onmicrosoft.com `
    -ClientId <app-id> -CertificateThumbprint <thumbprint> `
    -FoEnvironmentUrl https://contoso-prod.operations.dynamics.com `
    -TeamsWorkflowUrl (Get-Secret FoSecretExpiryTeamsUrl -AsPlainText)
```

Remember to add the report's own certificate to the report: it expires too.
