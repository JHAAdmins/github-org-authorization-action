param(
    [Parameter(Mandatory)] [string]$Token,
    [Parameter(Mandatory)] [string]$Org,
    [Parameter(Mandatory)] [string]$Repo,
    [string]$JsonExport = "false",
    [string]$CommitterName = "github-actions",
    [string]$CommitterEmail = "github-actions@github.com",
    [string]$SortAppColumn = "install_id",
    [string]$SortAppOrder = "desc",
    [string]$SortSshColumn = "credential_authorized_at",
    [string]$SortSshOrder = "desc",
    [string]$SortPatColumn = "credential_authorized_at",
    [string]$SortPatOrder = "desc",
    [string]$SortDeployKeyColumn = "date",
    [string]$SortDeployKeyOrder = "desc",
    [string]$Actor = "false",
    [string]$Branch = "main"
)

Write-Host "DEBUG: Org='$Org' Repo='$Repo' Token set=$($Token -ne $null)"
if (-not $Org)   { throw "Missing required param: Org" }
if (-not $Token) { throw "Missing required param: Token" }
if (-not $Repo)  { throw "Missing required param: Repo" }

$ProgressPreference = 'SilentlyContinue'
$ErrorActionPreference = 'Stop'

function Encode-Base64([string]$Text) {
    [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($Text))
}

function Invoke-GitHubApi {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [hashtable]$Headers = @{},
        [object]$Body = $null
    )
    $Headers['Authorization'] = "Bearer $Token"
    $Headers['Accept'] = "application/vnd.github+json"

     Write-Host "DEBUG: Invoking GitHub API with Uri='$Uri'"
     
    if ($Method -eq 'GET') {
        Invoke-RestMethod -Uri $Uri -Headers $Headers -Method $Method
    } else {
        Invoke-RestMethod -Uri $Uri -Headers $Headers -Method $Method -Body ($Body | ConvertTo-Json -Depth 10) -ContentType "application/json"
    }
}

function Invoke-GitHubPagedApi {
    param(
        [string]$Uri
    )
    Write-Host "DEBUG: Entered Invoke-GitHubPagedApi with Uri='$Uri'"
    if ([string]::IsNullOrWhiteSpace($Uri)) {
        throw "Invoke-GitHubPagedApi called with blank Uri"
    }
    $baseUri = $Uri
    $results = @()
    $page = 1
    while ($true) {
        Write-Host "DEBUG: Loop start - `\$baseUri='$baseUri', `\$page=$page"
        $pagedUri = if ($baseUri -match "\?") { "$baseUri&per_page=100&page=$page" } else { "$baseUri?per_page=100&page=$page" }
        Write-Host "DEBUG: Calling Invoke-GitHubApi with pagedUri='$pagedUri'"
        $resp = Invoke-GitHubApi -Uri $pagedUri
        if ($null -eq $resp) { break }
        if ($resp -is [System.Collections.IEnumerable] -and -not ($resp -is [string])) {
            $results += $resp
            if ($resp.Count -lt 100) { break }
        } else {
            $results += $resp
            break
        }
        $page++
    }
    return $results
}

function Order-Array {
    param(
        [array]$Array,
        [string]$Column,
        [string]$Order = "desc"
    )
    if ($Array.Count -eq 0 -or -not $Array[0].PSObject.Properties.Name -contains $Column) { return $Array }
    $colType = $Array[0].PSObject.Properties[$Column].Value.GetType().Name
    if ($colType -eq "DateTime" -or $Column -match "date|created|at|updated|expires") {
        $Array = $Array | Sort-Object { [datetime]::Parse($_.$Column) } -Descending:($Order -eq "desc")
    } else {
        $Array = $Array | Sort-Object $Column -Descending:($Order -eq "desc")
    }
    return $Array
}

function Write-File([string]$Content, [string]$Path) {
    [System.IO.File]::WriteAllText($Path, $Content)
}

function Write-CsvFile($Data, $Path) {
    $Data | Export-Csv -Path $Path -NoTypeInformation -Force
}
function Write-JsonFile($Data, $Path) {
    $Data | ConvertTo-Json -Depth 10 | Set-Content -Path $Path -Force
}

function Push-Report-To-GitHub {
    param(
        [string]$FilePath,    # Path relative to repo root, e.g. "reports/org-SSH-list.csv"
        [string]$LocalPath,   # Local file path
        [string]$CommitMsg
    )
    # 1. Read file, encode to base64
    $contentRaw = [System.IO.File]::ReadAllText($LocalPath)
    $contentB64 = Encode-Base64 $contentRaw

    # 2. Try to get existing file SHA (for update)
    $owner, $repo = $Repo.Split('/')
    $getUri = "https://api.github.com/repos/$owner/$repo/contents/$FilePath`?ref=$Branch"
    $sha = $null
    try {
        $resp = Invoke-GitHubApi -Uri $getUri -Method 'GET'
        $sha = $resp.sha
    } catch { $sha = $null }

    # 3. Prepare request body
    $body = @{
        message = $CommitMsg
        content = $contentB64
        branch = $Branch
        committer = @{
            name = $CommitterName
            email = $CommitterEmail
        }
        author = @{
            name = $CommitterName
            email = $CommitterEmail
        }
    }
    if ($sha) { $body.sha = $sha }

    # 4. Upload
    $putUri = "https://api.github.com/repos/$owner/$repo/contents/$FilePath"
    Invoke-GitHubApi -Uri $putUri -Method 'PUT' -Body $body | Out-Null
    Write-Host "Pushed $FilePath"
}

$Today = [DateTime]::UtcNow.ToString("yyyy-MM-dd")

# 1. Retrieve PATs and SSH Keys
Write-Host "Retrieving PATs and SSH keys..."
$patsshArray = Invoke-GitHubPagedApi -Uri "https://api.github.com/orgs/$Org/credential-authorizations"
$sshArray = @()
$patArray = @()
foreach ($auth in $patsshArray) {
    if ($auth.credential_type -eq "SSH key") {
        $sshArray += [PSCustomObject]@{
            login                     = $auth.login
            credential_authorized_at  = $auth.credential_authorized_at
            credential_accessed_at    = $auth.credential_accessed_at
            authorized_credential_title = $auth.authorized_credential_title
        }
    } else {
        $scopeMap = @{}
        foreach ($scope in $auth.scopes) { $scopeMap[$scope] = $true }
        $patArray += [PSCustomObject]@{
            login                     = $auth.login
            credential_authorized_at  = $auth.credential_authorized_at
            credential_accessed_at    = $auth.credential_accessed_at
            authorized_credential_expires_at = $auth.authorized_credential_expires_at
            authorized_credential_note = $auth.authorized_credential_note
            repo                      = $scopeMap["repo"]
            repo_status               = $scopeMap["repo:status"]
            repo_deployment           = $scopeMap["repo:deployment"]
            public_repo               = $scopeMap["public_repo"]
            repo_invite               = $scopeMap["repo:invite"]
            security_events           = $scopeMap["security_events"]
            workflow                  = $scopeMap["workflow"]
            write_packages            = $scopeMap["write:packages"]
            read_packages             = $scopeMap["read:packages"]
            delete_packages           = $scopeMap["delete:packages"]
            admin_org                 = $scopeMap["admin:org"]
            write_org                 = $scopeMap["write:org"]
            read_org                  = $scopeMap["read:org"]
            admin_public_key          = $scopeMap["admin:public_key"]
            write_public_key          = $scopeMap["write:public_key"]
            read_public_key           = $scopeMap["read:public_key"]
            admin_repo_hook           = $scopeMap["admin:repo_hook"]
            write_repo_hook           = $scopeMap["write:repo_hook"]
            read_repo_hook            = $scopeMap["read:repo_hook"]
            admin_org_hook            = $scopeMap["admin:org_hook"]
            gist                      = $scopeMap["gist"]
            notifications             = $scopeMap["notifications"]
            user                      = $scopeMap["user"]
            read_user                 = $scopeMap["read:user"]
            user_email                = $scopeMap["user:email"]
            user_follow               = $scopeMap["user:follow"]
            delete_repo               = $scopeMap["delete_repo"]
            write_discussion          = $scopeMap["write:discussion"]
            read_discussion           = $scopeMap["read:discussion"]
            admin_enterprise          = $scopeMap["admin:enterprise"]
            manage_runners_enterprise = $scopeMap["manage_runners:enterprise"]
            manage_billing_enterprise = $scopeMap["manage_billing:enterprise"]
            read_enterprise           = $scopeMap["read:enterprise"]
            site_admin                = $scopeMap["site_admin"]
            devtools                  = $scopeMap["devtools"]
            biztools                  = $scopeMap["biztools"]
            codespace                 = $scopeMap["codespace"]
            codespace_secrets         = $scopeMap["codespace:secrets"]
            admin_gpg_key             = $scopeMap["admin:gpg_key"]
            write_gpg_key             = $scopeMap["write:gpg_key"]
            read_gpg_key              = $scopeMap["read:gpg_key"]
        }
    }
}

# 2. Write and push SSH and PAT reports
$ReportsDir = "reports"
if (-not (Test-Path $ReportsDir)) { New-Item -ItemType Directory -Path $ReportsDir | Out-Null }
$sshCsv = "$ReportsDir/$Org-SSH-list.csv"
$patCsv = "$ReportsDir/$Org-PAT-list.csv"
$sshArray = Order-Array $sshArray $SortSshColumn $SortSshOrder
$patArray = Order-Array $patArray $SortPatColumn $SortPatOrder
Write-CsvFile $sshArray $sshCsv
Write-CsvFile $patArray $patCsv
Push-Report-To-GitHub -FilePath "reports/$Org-SSH-list.csv" -LocalPath $sshCsv -CommitMsg "$Today Authorization report"
Push-Report-To-GitHub -FilePath "reports/$Org-PAT-list.csv" -LocalPath $patCsv -CommitMsg "$Today Authorization report"
if ($JsonExport -eq "true") {
    $sshJson = "$ReportsDir/$Org-SSH-list.json"
    $patJson = "$ReportsDir/$Org-PAT-list.json"
    Write-JsonFile $sshArray $sshJson
    Write-JsonFile $patArray $patJson
    Push-Report-To-GitHub -FilePath "reports/$Org-SSH-list.json" -LocalPath $sshJson -CommitMsg "$Today Authorization report"
    Push-Report-To-GitHub -FilePath "reports/$Org-PAT-list.json" -LocalPath $patJson -CommitMsg "$Today Authorization report"
}

# 3. Retrieve and push Deploy Keys (GraphQL)
Write-Host "Retrieving deploy keys..."
$deployKeysQuery = @'
query (\$org: String!, \$cursorID: String) {
  organization(login: \$org) {
    repositories(first: 100, after: \$cursorID) {
      nodes {
        name
        deployKeys(first: 100) {
          totalCount
          nodes {
            title
            createdAt
            readOnly
            id
          }
        }
      }
      pageInfo {
        hasNextPage
        endCursor
      }
    }
  }
}
'@
$deployKeyArray = @()
$cursorID = $null
do {
    $body = @{
        query = $deployKeysQuery
        variables = @{ org = $Org; cursorID = $cursorID }
    }
    $result = Invoke-GitHubApi -Uri "https://api.github.com/graphql" -Method Post -Body $body
    $repos = $result.data.organization.repositories.nodes
    foreach ($repo in $repos) {
        foreach ($key in $repo.deployKeys.nodes) {
            $deployKeyArray += [PSCustomObject]@{
                repo = $repo.name
                date = $key.createdAt.Substring(0, 10)
                readOnly = $key.readOnly
                title = $key.title
            }
        }
    }
    $hasNextPage = $result.data.organization.repositories.pageInfo.hasNextPage
    $cursorID = $result.data.organization.repositories.pageInfo.endCursor
} while ($hasNextPage)

$deployKeyArray = Order-Array $deployKeyArray $SortDeployKeyColumn $SortDeployKeyOrder
$deployKeyCsv = "$ReportsDir/$Org-DEPLOYKEY-list.csv"
Write-CsvFile $deployKeyArray $deployKeyCsv
Push-Report-To-GitHub -FilePath "reports/$Org-DEPLOYKEY-list.csv" -LocalPath $deployKeyCsv -CommitMsg "$Today Authorization report"
if ($JsonExport -eq "true") {
    $deployKeyJson = "$ReportsDir/$Org-DEPLOYKEY-list.json"
    Write-JsonFile $deployKeyArray $deployKeyJson
    Push-Report-To-GitHub -FilePath "reports/$Org-DEPLOYKEY-list.json" -LocalPath $deployKeyJson -CommitMsg "$Today Authorization report"
}

# 4. Retrieve App Installer/RepoAdder Audit Log
$appInstallerArray = @()
$appRepoadderArray = @()
if ($Actor -eq "true") {
    Write-Host "Retrieving app installer/repoadder audit log..."
    $auditLogArray = Invoke-GitHubPagedApi -Uri "https://api.github.com/orgs/$Org/audit-log"
    foreach ($auth in $auditLogArray) {
        if ($auth.action -eq 'integration_installation.create') {
            $appInstallerArray += [PSCustomObject]@{
                name = $auth.name.ToLower() -replace '[^a-z0-9]+',' '
                actor = $auth.actor
            }
        }
        elseif ($auth.action -eq 'integration_installation.repositories_added') {
            $appRepoadderArray += [PSCustomObject]@{
                name = $auth.name.ToLower() -replace '[^a-z0-9]+',' '
                actor = $auth.actor
            }
        }
    }
    # Deduplicate by name, aggregate actors
    $appInstallerArray = $appInstallerArray | Group-Object name | ForEach-Object {
        [PSCustomObject]@{ name=$_.Name; actor=($_.Group.actor -join ", ") }
    }
    $appRepoadderArray = $appRepoadderArray | Group-Object name | ForEach-Object {
        [PSCustomObject]@{ name=$_.Name; actor=($_.Group.actor -join ", ") }
    }
}

# 5. Retrieve, write, and push GitHub App installations
Write-Host "Retrieving GitHub Apps..."
$appsApi = "https://api.github.com/orgs/$Org/installations"
$appInstalls = Invoke-GitHubPagedApi -Uri $appsApi
$appArray = @()
foreach ($auth in $appInstalls) {
    $slugActor = $auth.app_slug.ToLower() -replace '[^a-z0-9]+',' '
    $installer = ($appInstallerArray | Where-Object { $_.name -eq $slugActor }).actor
    $repoadder = ($appRepoadderArray | Where-Object { $_.name -eq $slugActor }).actor
    $perms = $auth.permissions
    $appArray += [PSCustomObject]@{
        slug = $auth.app_slug
        install_id = $auth.id
        app_id = $auth.app_id
        repos = $auth.repository_selection
        created = $auth.created_at.Substring(0, 10)
        updated = $auth.updated_at.Substring(0, 10)
        suspended = if ($null -eq $auth.suspended_at) { "" } else { $auth.suspended_at.Substring(0, 10) }
        pages = $perms.pages
        checks = $perms.checks
        issues = $perms.issues
        actions = $perms.actions
        members = $perms.members
        secrets = $perms.secrets
        contents = $perms.contents
        metadata = $perms.metadata
        packages = $perms.packages
        statuses = $perms.statuses
        workflows = $perms.workflows
        deployments = $perms.deployments
        discussions = $perms.discussions
        single_file = $perms.single_file
        environments = $perms.environments
        pull_requests = $perms.pull_requests
        administration = $perms.administration
        security_events = $perms.security_events
        repository_hooks = $perms.repository_hooks
        team_discussions = $perms.team_discussions
        organization_plan = $perms.organization_plan
        dependabot_secrets = $perms.dependabot_secrets
        organization_hooks = $perms.organization_hooks
        organization_events = $perms.organization_events
        repository_projects = $perms.repository_projects
        organization_secrets = $perms.organization_secrets
        vulnerability_alerts = $perms.vulnerability_alerts
        organization_packages = $perms.organization_packages
        organization_projects = $perms.organization_projects
        secret_scanning_alerts = $perms.secret_scanning_alerts
        organization_user_blocking = $perms.organization_user_blocking
        organization_administration = $perms.organization_administration
        organization_dependabot_secrets = $perms.organization_dependabot_secrets
        organization_self_hosted_runners = $perms.organization_self_hosted_runners
        installer = $installer
        repoadder = $repoadder
    }
}
$appArray = Order-Array $appArray $SortAppColumn $SortAppOrder
$appCsv = "$ReportsDir/$Org-APP-list.csv"
Write-CsvFile $appArray $appCsv
Push-Report-To-GitHub -FilePath "reports/$Org-APP-list.csv" -LocalPath $appCsv -CommitMsg "$Today Authorization report"
if ($JsonExport -eq "true") {
    $appJson = "$ReportsDir/$Org-APP-list.json"
    Write-JsonFile $appArray $appJson
    Push-Report-To-GitHub -FilePath "reports/$Org-APP-list.json" -LocalPath $appJson -CommitMsg "$Today Authorization report"
}

Write-Host "All reports generated in: $ReportsDir and pushed to $Repo@$Branch"
