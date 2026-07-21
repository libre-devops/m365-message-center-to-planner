#Requires -Version 7.0
<#
.SYNOPSIS
Message Center CLI: read M365 Message Center posts and push them to Microsoft Planner.

.DESCRIPTION
PowerShell twin of mc.py (same commands, filters, and behaviour), for machines where Python is not
an option. Always your own identity, never an app secret, via one of three modes (-Auth, or MC_AUTH
in the environment): az reuses the Azure CLI login through `az rest`; device signs you in with a
device code through the Microsoft Graph Command Line Tools public client; interactive does a normal
browser sign-in with the same client for tenants whose Conditional Access blocks device code. The
device and interactive flows are implemented with plain Invoke-RestMethod, so the script has no
module dependencies at all.

Reading messages needs a Message Center capable role (Message Center Reader is enough); writing to
Planner needs nothing beyond membership of the group that owns the plan.

.PARAMETER Command
messages (list posts), summarise (markdown rollup), post (create Planner tasks), plans (find plan
and bucket ids for a group), or help.

.EXAMPLE
./mc.ps1 messages -Service xdr -Week this

.EXAMPLE
./mc.ps1 messages -Service purview,azure -Month last -OutCsv messages.csv

.EXAMPLE
./mc.ps1 summarise -Major -Month this -OutFile summary.md

.EXAMPLE
./mc.ps1 post -PlanId <planId> -Severity critical -Week last -DryRun

.EXAMPLE
./mc.ps1 plans -GroupName "Platform Team" -Buckets
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Script parameters are read inside nested functions, which the rule cannot see across scopes.')]
param(
    [Parameter(Position = 0)]
    [ValidateSet('messages', 'summarise', 'post', 'plans', 'help')]
    [string]$Command = 'help',

    # Shared filters
    [string[]]$Service = @(),
    [string]$Category,
    [ValidateSet('', 'normal', 'high', 'critical')]
    [string]$Severity = '',
    [switch]$Major,
    [string]$Day,
    [string]$Week,
    [string]$Month,
    [string]$Year,
    [ValidateSet('lastModifiedDateTime', 'startDateTime')]
    [string]$DateField = 'lastModifiedDateTime',

    # messages
    [ValidateSet('table', 'json', 'ids')]
    [string]$Output = 'table',
    [int]$Limit = 0,
    [string]$OutCsv,

    # summarise
    [string]$OutFile,

    # post
    [string]$PlanId = $env:MC_PLAN_ID,
    [string]$BucketName = 'To be discussed',
    [switch]$Rollup,
    [switch]$DryRun,

    # plans
    [string]$GroupName,
    [switch]$Buckets,

    # auth
    [ValidateSet('az', 'device', 'interactive')]
    [string]$Auth = $(if ($env:MC_AUTH) { $env:MC_AUTH } else { 'az' }),
    [string]$Tenant = $(if ($env:MC_TENANT) { $env:MC_TENANT } else { 'organizations' })
)

# StrictMode 1.0, deliberately not Latest: the script consumes dynamic Graph JSON where properties
# are legitimately absent (ConvertFrom-Json only materialises what the reply contained), and 2.0+
# turns every such access, and every synthetic .Count on a scalar, into a runtime error. 1.0 keeps
# the protection that matters here (uninitialised variables) without the landmines.
Set-StrictMode -Version 1.0
$ErrorActionPreference = 'Stop'

$script:GraphBase = 'https://graph.microsoft.com/v1.0'
$script:AdminLink = 'https://admin.microsoft.com/#/MessageCenter/:/messages/{0}'

# The Microsoft Graph Command Line Tools public client (the app Connect-MgGraph uses). Unlike the
# Azure CLI's first-party app, it is allowed to request these delegated Graph scopes dynamically,
# so device/interactive auth works where az scoped logins die with AADSTS65002.
$script:GraphCliApp = '14d82eec-204b-4c2f-b7e8-296a70dab67e'
$script:Scopes = @('ServiceMessage.Read.All', 'Tasks.ReadWrite', 'Group.Read.All', 'offline_access')
$script:CachePath = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config/m365-mc-planner/token-cache-ps.json'

# Short names for the services people actually say, matched (case-insensitive) as substrings
# against the message's services list. Anything not in this table is used as a raw substring.
$script:ServiceAliases = @{
    xdr = @('defender xdr', '365 defender')
    defender = @('defender')
    mde = @('defender for endpoint')
    mdo = @('defender for office')
    purview = @('purview')
    azure = @('azure')
    entra = @('entra', 'azure ad', 'identity')
    intune = @('intune')
    teams = @('teams')
    exchange = @('exchange')
    sharepoint = @('sharepoint')
    onedrive = @('onedrive')
    copilot = @('copilot')
    sentinel = @('sentinel')
    planner = @('planner')
    power = @('power apps', 'power automate', 'power bi', 'power platform')
}

$script:CategoryAliases = @{
    plan = 'planForChange'
    planforchange = 'planForChange'
    stay = 'stayInformed'
    stayinformed = 'stayInformed'
    prevent = 'preventOrFixIssue'
    preventorfixissue = 'preventOrFixIssue'
}

# ---------------------------------------------------------------------------- auth and Graph

function Write-PermissionHint {
    Write-Host ''
    Write-Host 'This is a permissions problem, not a script problem. Check that:' -ForegroundColor Yellow
    Write-Host '  1. You are signed in to the right tenant (az account show, or -Tenant for device/interactive).' -ForegroundColor Yellow
    Write-Host '  2. Reading messages: your account holds a Message Center capable admin role' -ForegroundColor Yellow
    Write-Host '     (Message Center Reader is enough).' -ForegroundColor Yellow
    Write-Host '  3. Posting to Planner: you are a member of the group that owns the plan.' -ForegroundColor Yellow
    Write-Host '  4. In az mode a 403 usually means the Azure CLI token lacks the Graph scopes, and' -ForegroundColor Yellow
    Write-Host '     Microsoft does not let the az app request them (AADSTS65002). Switch modes:' -ForegroundColor Yellow
    Write-Host '     ./mc.ps1 <command> -Auth device     (or interactive, or export MC_AUTH)' -ForegroundColor Yellow
}

function Save-TokenCache {
    param([hashtable]$Cache)
    $dir = Split-Path $script:CachePath -Parent
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $Cache | ConvertTo-Json | Set-Content -Path $script:CachePath -NoNewline
    if (-not $IsWindows) { chmod 600 $script:CachePath }
}

function Invoke-TokenEndpoint {
    param([hashtable]$Body)
    $uri = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/token"
    try {
        return Invoke-RestMethod -Method Post -Uri $uri -Body $Body
    }
    catch {
        $detail = $null
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $detail = $_.ErrorDetails.Message | ConvertFrom-Json }
        if ($detail -and $detail.error -eq 'authorization_pending') { return $detail }
        if ($detail) { throw "Token request failed: $($detail.error): $($detail.error_description)" }
        throw
    }
}

function Get-UserToken {
    if (Get-Variable -Name McAccessToken -Scope Script -ErrorAction SilentlyContinue) { return $script:McAccessToken }

    # Cached token first, refreshed when stale.
    if (Test-Path $script:CachePath) {
        $cache = Get-Content $script:CachePath -Raw | ConvertFrom-Json
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($cache.expires_on - 120 -gt $now) {
            $script:McAccessToken = $cache.access_token
            return $script:McAccessToken
        }
        if ($cache.refresh_token) {
            try {
                $r = Invoke-TokenEndpoint -Body @{
                    client_id = $script:GraphCliApp; grant_type = 'refresh_token'
                    refresh_token = $cache.refresh_token; scope = ($script:Scopes -join ' ')
                }
                if ($r.access_token) {
                    Save-TokenCache @{
                        access_token = $r.access_token
                        refresh_token = $(if ($r.refresh_token) { $r.refresh_token } else { $cache.refresh_token })
                        expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [int]$r.expires_in
                    }
                    $script:McAccessToken = $r.access_token
                    return $script:McAccessToken
                }
            }
            catch {
                Write-Verbose "Refresh failed, falling through to a fresh sign-in: $_"
            }
        }
    }

    if ($Auth -eq 'interactive') {
        $token = Get-TokenInteractive
    }
    else {
        $token = Get-TokenDeviceCode
    }
    $script:McAccessToken = $token
    return $token
}

function Get-TokenDeviceCode {
    $dc = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/devicecode" -Body @{
        client_id = $script:GraphCliApp; scope = ($script:Scopes -join ' ')
    }
    Write-Host $dc.message -ForegroundColor Cyan
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds([int]$dc.expires_in)
    while ([DateTimeOffset]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds ([int]$dc.interval)
        $r = Invoke-TokenEndpoint -Body @{
            client_id = $script:GraphCliApp
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
            device_code = $dc.device_code
        }
        if ($r.PSObject.Properties.Name -contains 'access_token' -and $r.access_token) {
            Save-TokenCache @{
                access_token = $r.access_token
                refresh_token = $r.refresh_token
                expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [int]$r.expires_in
            }
            return $r.access_token
        }
    }
    throw 'Device code sign-in timed out. If Conditional Access blocks device code, try -Auth interactive.'
}

function Get-TokenInteractive {
    # Authorization code flow with PKCE on a localhost listener, no dependencies.
    $port = Get-Random -Minimum 8400 -Maximum 8999
    $redirect = "http://localhost:$port/"
    $bytes = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $verifier = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    $sha = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::ASCII.GetBytes($verifier))
    $challenge = [Convert]::ToBase64String($sha).TrimEnd('=').Replace('+', '-').Replace('/', '_')

    $authUrl = "https://login.microsoftonline.com/$Tenant/oauth2/v2.0/authorize" +
    "?client_id=$script:GraphCliApp&response_type=code&redirect_uri=$([uri]::EscapeDataString($redirect))" +
    "&scope=$([uri]::EscapeDataString($script:Scopes -join ' '))" +
    "&code_challenge=$challenge&code_challenge_method=S256&prompt=select_account"

    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($redirect)
    $listener.Start()
    Write-Host "Opening a browser to sign in. If nothing opens, browse to:" -ForegroundColor Cyan
    Write-Host $authUrl
    try { Start-Process $authUrl } catch { Write-Verbose 'Could not auto-open a browser.' }

    try {
        $ctx = $listener.GetContext()
        $code = $ctx.Request.QueryString['code']
        $err = $ctx.Request.QueryString['error_description']
        $html = '<html><body><h3>Signed in. You can close this tab.</h3></body></html>'
        $buf = [Text.Encoding]::UTF8.GetBytes($html)
        $ctx.Response.ContentType = 'text/html'
        $ctx.Response.OutputStream.Write($buf, 0, $buf.Length)
        $ctx.Response.Close()
    }
    finally {
        $listener.Stop()
    }
    if (-not $code) { throw "Interactive sign-in failed: $err" }

    $r = Invoke-TokenEndpoint -Body @{
        client_id = $script:GraphCliApp; grant_type = 'authorization_code'
        code = $code; redirect_uri = $redirect; code_verifier = $verifier
        scope = ($script:Scopes -join ' ')
    }
    Save-TokenCache @{
        access_token = $r.access_token
        refresh_token = $r.refresh_token
        expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + [int]$r.expires_in
    }
    return $r.access_token
}

function Invoke-Graph {
    param(
        [Parameter(Mandatory)][string]$Method,
        [Parameter(Mandatory)][string]$Url,
        $Body,
        [hashtable]$Headers = @{}
    )
    if ($Auth -eq 'az') {
        $azArgs = @('rest', '--method', $Method, '--url', $Url, '--output', 'json')
        if ($null -ne $Body) { $azArgs += @('--body', ($Body | ConvertTo-Json -Depth 20 -Compress)) }
        foreach ($k in $Headers.Keys) { $azArgs += @('--headers', "$k=$($Headers[$k])") }
        $out = & az @azArgs 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Host "Graph call failed: $($Method.ToUpper()) $Url" -ForegroundColor Red
            $errText = ($out | Out-String)
            Write-Host $errText.Substring(0, [Math]::Min(2000, $errText.Length))
            if ($errText -match '403|Forbidden|Insufficient privileges|UnknownError') { Write-PermissionHint }
            exit 1
        }
        $text = ($out | Out-String).Trim()
        if ($text) { return $text | ConvertFrom-Json } else { return $null }
    }

    $token = Get-UserToken
    $params = @{
        Method = $Method
        Uri = $Url
        Headers = ($Headers + @{ Authorization = "Bearer $token" })
    }
    if ($null -ne $Body) {
        $params.ContentType = 'application/json'
        $params.Body = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $status = $null
        if ($_.Exception.PSObject.Properties.Name -contains 'Response' -and $_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        Write-Host "Graph call failed ($status): $($Method.ToUpper()) $Url" -ForegroundColor Red
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) { Write-Host $_.ErrorDetails.Message.Substring(0, [Math]::Min(2000, $_.ErrorDetails.Message.Length)) }
        if ($status -eq 403) { Write-PermissionHint }
        exit 1
    }
}

function Get-GraphAll {
    param([Parameter(Mandatory)][string]$Url)
    $items = @()
    while ($Url) {
        $page = Invoke-Graph -Method get -Url $Url
        if ($null -ne $page -and $page.PSObject.Properties.Name -contains 'value') { $items += $page.value }
        $Url = if ($page -and $page.PSObject.Properties.Name -contains '@odata.nextLink') { $page.'@odata.nextLink' } else { $null }
    }
    return $items
}

# ---------------------------------------------------------------------------- filtering

function Limit-Text {
    param([string]$Text, [int]$Max)
    if ($Text -and $Text.Length -gt $Max) { return $Text.Substring(0, $Max) }
    return $Text
}

function Get-Period {
    # @() around the pipeline matters: Where-Object returns a bare scalar when exactly one value
    # matches, and a scalar has no .Count (caught live on the first Windows run).
    $supplied = @(@($Day, $Week, $Month, $Year) | Where-Object { $_ })
    if ($supplied.Count -eq 0) { return $null }
    if ($supplied.Count -gt 1) { throw 'Use only one of -Day, -Week, -Month, -Year.' }
    $today = [DateTime]::UtcNow.Date

    if ($Day) {
        $d = switch ($Day) {
            'today' { $today }
            'yesterday' { $today.AddDays(-1) }
            default { [DateTime]::ParseExact($Day, 'yyyy-MM-dd', $null) }
        }
        return @{ Start = $d; End = $d.AddDays(1); Label = "day $($d.ToString('yyyy-MM-dd'))" }
    }
    if ($Week) {
        if ($Week -in @('this', 'last')) {
            $anchor = if ($Week -eq 'this') { $today } else { $today.AddDays(-7) }
            $y = [System.Globalization.ISOWeek]::GetYear($anchor)
            $w = [System.Globalization.ISOWeek]::GetWeekOfYear($anchor)
        }
        elseif ($Week -match '^(\d{4})-W(\d{1,2})$') {
            $y = [int]$Matches[1]; $w = [int]$Matches[2]
        }
        else {
            throw 'Week must be this, last, or ISO form like 2026-W29.'
        }
        $monday = [System.Globalization.ISOWeek]::ToDateTime($y, $w, [DayOfWeek]::Monday)
        return @{ Start = $monday; End = $monday.AddDays(7); Label = ('week {0}-W{1:d2}' -f $y, $w) }
    }
    if ($Month) {
        if ($Month -in @('this', 'last')) {
            $anchor = [DateTime]::new($today.Year, $today.Month, 1)
            if ($Month -eq 'last') { $anchor = $anchor.AddMonths(-1) }
        }
        elseif ($Month -match '^(\d{4})-(\d{1,2})$') {
            $anchor = [DateTime]::new([int]$Matches[1], [int]$Matches[2], 1)
        }
        else {
            throw 'Month must be this, last, or ISO form like 2026-07.'
        }
        return @{ Start = $anchor; End = $anchor.AddMonths(1); Label = "month $($anchor.ToString('yyyy-MM'))" }
    }
    $start = [DateTime]::new([int]$Year, 1, 1)
    return @{ Start = $start; End = $start.AddYears(1); Label = "year $Year" }
}

function Test-ServiceMatch {
    param($Message)
    if ($Service.Count -eq 0) { return $true }
    $svc = (($Message.services ?? @()) -join ' | ').ToLowerInvariant()
    foreach ($term in $Service) {
        $needles = if ($script:ServiceAliases.ContainsKey($term.ToLowerInvariant())) { $script:ServiceAliases[$term.ToLowerInvariant()] } else { @($term.ToLowerInvariant()) }
        foreach ($needle in $needles) {
            if ($svc.Contains($needle)) { return $true }
        }
    }
    return $false
}

function Get-FilteredMessageSet {
    $period = Get-Period
    $wantCategory = $null
    if ($Category) {
        $key = $Category.ToLowerInvariant()
        if (-not $script:CategoryAliases.ContainsKey($key)) { throw 'Category must be one of: planForChange, stayInformed, preventOrFixIssue.' }
        $wantCategory = $script:CategoryAliases[$key]
    }
    $all = Get-GraphAll -Url "$script:GraphBase/admin/serviceAnnouncement/messages?`$top=100"
    $filtered = foreach ($m in $all) {
        if (-not (Test-ServiceMatch -Message $m)) { continue }
        if ($wantCategory -and $m.category -ne $wantCategory) { continue }
        if ($Severity -and $m.severity -ne $Severity) { continue }
        if ($Major -and -not $m.isMajorChange) { continue }
        if ($period) {
            $raw = $m.$DateField
            if (-not $raw) { continue }
            $when = ([DateTimeOffset]::Parse($raw)).UtcDateTime
            if ($when -lt $period.Start -or $when -ge $period.End) { continue }
        }
        $m
    }
    $sorted = @($filtered | Sort-Object -Property @{ Expression = { $_.$DateField } } -Descending)
    return @{ Messages = $sorted; Period = $period }
}

function ConvertTo-PlainText {
    param([string]$Html, [int]$Cap = 2000)
    if (-not $Html) { return '' }
    $t = $Html -replace '(?is)<(script|style)[^>]*>.*?</\1>', ' '
    $t = $t -replace '(?i)<br\s*/?>|</p>|</li>', "`n"
    $t = $t -replace '<[^>]+>', ' '
    $t = [System.Net.WebUtility]::HtmlDecode($t)
    $t = $t -replace '[ \t]+', ' '
    $t = ($t -replace "\n\s*\n\s*", "`n`n").Trim()
    if ($t.Length -gt $Cap) { return $t.Substring(0, $Cap) + ' ...' }
    return $t
}

function Get-Summary {
    param($Messages, $Period)
    $bits = @()
    if ($Period) { $bits += $Period.Label }
    if ($Service.Count) { $bits += 'services: ' + ($Service -join ', ') }
    if ($Category) { $bits += "category: $Category" }
    if ($Severity) { $bits += "severity: $Severity" }
    $label = if ($bits) { $bits -join '; ' } else { 'all messages' }

    $critical = @($Messages | Where-Object { $_.severity -eq 'critical' }).Count
    $high = @($Messages | Where-Object { $_.severity -eq 'high' }).Count
    $normal = @($Messages | Where-Object { -not $_.severity -or $_.severity -eq 'normal' }).Count

    $lines = @(
        "# Message Center summary ($label)"
        ''
        "Total: $($Messages.Count) messages ($critical critical, $high high, $normal normal)"
        ''
        '## By service'
    )
    $byService = @{}
    foreach ($m in $Messages) {
        foreach ($s in ($m.services ?? @('(none)'))) { $byService[$s] = 1 + ($byService[$s] ?? 0) }
    }
    foreach ($e in ($byService.GetEnumerator() | Sort-Object -Property Value -Descending)) { $lines += "- $($e.Key): $($e.Value)" }

    $lines += @('', '## By category')
    $byCat = @{}
    foreach ($m in $Messages) { $c = $m.category ?? '(none)'; $byCat[$c] = 1 + ($byCat[$c] ?? 0) }
    foreach ($e in ($byCat.GetEnumerator() | Sort-Object -Property Value -Descending)) { $lines += "- $($e.Key): $($e.Value)" }

    $action = @($Messages | Where-Object { $_.actionRequiredByDateTime })
    if ($action) {
        $lines += @('', '## Action required')
        foreach ($m in ($action | Sort-Object actionRequiredByDateTime)) {
            $lines += "- $($m.id) due $($m.actionRequiredByDateTime.Substring(0,10)): $($m.title)"
        }
    }

    $lines += @('', '## Messages')
    foreach ($m in $Messages) {
        $when = if ($m.$DateField) { $m.$DateField.Substring(0, 10) } else { '' }
        $lines += "- $($m.id) $when [$(($m.services ?? @()) -join ', ')] $($m.title)"
    }
    return $lines -join "`n"
}

# ---------------------------------------------------------------------------- commands

function Invoke-MessageList {
    $result = Get-FilteredMessageSet
    $msgs = $result.Messages
    if ($Limit -gt 0 -and $msgs.Count -gt $Limit) { $msgs = $msgs[0..($Limit - 1)] }

    if ($OutCsv) {
        $rows = foreach ($m in $msgs) {
            [pscustomobject]@{
                id = $m.id
                title = $m.title
                category = $m.category
                severity = $m.severity
                isMajorChange = [bool]$m.isMajorChange
                services = (($m.services ?? @()) -join '; ')
                tags = (($m.tags ?? @()) -join '; ')
                lastModifiedDateTime = $m.lastModifiedDateTime
                startDateTime = $m.startDateTime
                endDateTime = $m.endDateTime
                actionRequiredByDateTime = $m.actionRequiredByDateTime
                adminCenterLink = ($script:AdminLink -f $m.id)
                bodyText = (ConvertTo-PlainText -Html $m.body.content -Cap 1000)
            }
        }
        $rows | Export-Csv -Path $OutCsv -NoTypeInformation -Encoding utf8BOM
        Write-Host "Wrote $OutCsv ($($msgs.Count) messages)." -ForegroundColor Green
        return
    }
    if ($Output -eq 'json') { $msgs | ConvertTo-Json -Depth 20; return }
    if ($Output -eq 'ids') { $msgs | ForEach-Object { $_.id }; return }
    if (-not $msgs) { Write-Host 'No messages matched.' -ForegroundColor Yellow; return }
    $msgs | ForEach-Object {
        [pscustomobject]@{
            ID = $_.id
            Sev = $_.severity
            Modified = if ($_.$DateField) { $_.$DateField.Substring(0, 10) } else { '' }
            Services = ((($_.services ?? @()) -join ', ')[0..30] -join '')
            Title = (($_.title ?? '')[0..69] -join '')
        }
    } | Format-Table -AutoSize
    Write-Host "$($msgs.Count) message(s)." -ForegroundColor Green
}

function Invoke-Summarise {
    $result = Get-FilteredMessageSet
    $text = Get-Summary -Messages $result.Messages -Period $result.Period
    if ($OutFile) {
        Set-Content -Path $OutFile -Value $text
        Write-Host "Wrote $OutFile ($($result.Messages.Count) messages)." -ForegroundColor Green
    }
    else {
        $text
    }
}

function Invoke-PlanList {
    if (-not $GroupName) { throw 'plans needs -GroupName.' }
    $safe = $GroupName.Replace("'", "''")
    $groups = Get-GraphAll -Url "$script:GraphBase/groups?`$filter=displayName eq '$safe'&`$select=id,displayName"
    if (-not $groups) { throw "No group named '$GroupName' found (or no read access to it)." }
    foreach ($g in $groups) {
        Write-Host "Group: $($g.displayName) ($($g.id))" -ForegroundColor Cyan
        foreach ($p in (Get-GraphAll -Url "$script:GraphBase/groups/$($g.id)/planner/plans")) {
            Write-Host "  plan: $($p.title)  id: $($p.id)"
            if ($Buckets) {
                foreach ($b in (Get-GraphAll -Url "$script:GraphBase/planner/plans/$($p.id)/buckets")) {
                    Write-Host "    bucket: $($b.name)  id: $($b.id)"
                }
            }
        }
    }
}

function Invoke-Post {
    if (-not $PlanId) { throw 'post needs -PlanId (or MC_PLAN_ID in the environment). Find it with: ./mc.ps1 plans -GroupName "Your Team".' }
    $result = Get-FilteredMessageSet
    $msgs = $result.Messages
    if (-not $msgs) { Write-Host 'No messages matched; nothing to post.' -ForegroundColor Yellow; return }

    $existingTitles = @((Get-GraphAll -Url "$script:GraphBase/planner/plans/$PlanId/tasks") | ForEach-Object { $_.title ?? '' })

    $allBuckets = Get-GraphAll -Url "$script:GraphBase/planner/plans/$PlanId/buckets"
    $bucket = $allBuckets | Where-Object { $_.name -ieq $BucketName } | Select-Object -First 1
    if (-not $bucket) {
        if ($DryRun) {
            Write-Host "[dry-run] would create bucket '$BucketName'"
            $bucket = @{ id = '(new)' }
        }
        else {
            $bucket = Invoke-Graph -Method post -Url "$script:GraphBase/planner/buckets" -Body @{ name = $BucketName; planId = $PlanId; orderHint = ' !' }
            Write-Host "Created bucket '$BucketName'." -ForegroundColor Green
        }
    }

    function New-PlannerTask {
        param([string]$Title, [string]$Description, [string]$Due)
        if ($DryRun) {
            $suffix = if ($Due) { " (due $($Due.Substring(0,10)))" } else { '' }
            Write-Host "[dry-run] would create task: $Title$suffix"
            return
        }
        $body = @{ planId = $PlanId; bucketId = $bucket.id; title = $Title }
        if ($Due) { $body.dueDateTime = $Due }
        $task = Invoke-Graph -Method post -Url "$script:GraphBase/planner/tasks" -Body $body
        $details = Invoke-Graph -Method get -Url "$script:GraphBase/planner/tasks/$($task.id)/details"
        Invoke-Graph -Method patch -Url "$script:GraphBase/planner/tasks/$($task.id)/details" `
            -Body @{ description = $Description; previewType = 'description' } `
            -Headers @{ 'If-Match' = $details.'@odata.etag' } | Out-Null
        Write-Host "Created: $Title" -ForegroundColor Green
    }

    if ($Rollup) {
        $label = if ($result.Period) { $result.Period.Label } else { [DateTime]::UtcNow.ToString('yyyy-MM-dd') }
        $title = "Message Center rollup: $label ($($msgs.Count) messages)"
        if ($existingTitles -contains $title) {
            Write-Host "Rollup task already exists, skipping: $title" -ForegroundColor Yellow
            return
        }
        $summary = Get-Summary -Messages $msgs -Period $result.Period
        if ($summary.Length -gt 20000) { $summary = $summary.Substring(0, 20000) }
        New-PlannerTask -Title $title -Description $summary -Due $null
        return
    }

    $created = 0; $skipped = 0
    foreach ($m in $msgs) {
        $title = "$($m.id): $(($m.title ?? '').Trim())"
        if ($title.Length -gt 255) { $title = $title.Substring(0, 255) }
        if (@($existingTitles | Where-Object { $_.StartsWith($m.id) }).Count -gt 0) { $skipped++; continue }
        $bodyText = ConvertTo-PlainText -Html $m.body.content
        $description = @(
            "Services: $(($m.services ?? @()) -join ', ')"
            "Category: $($m.category)  Severity: $($m.severity)  Major change: $([bool]$m.isMajorChange)"
            "Last modified: $(if ($m.lastModifiedDateTime) { $m.lastModifiedDateTime.Substring(0,10) })"
            "Admin center: $($script:AdminLink -f $m.id)"
            ''
            $bodyText
        ) -join "`n"
        New-PlannerTask -Title $title -Description $description -Due $m.actionRequiredByDateTime
        $created++
    }
    Write-Host "Done: $created created, $skipped already present." -ForegroundColor Green
}

# ---------------------------------------------------------------------------- dispatch

switch ($Command) {
    'messages' { Invoke-MessageList }
    'summarise' { Invoke-Summarise }
    'post' { Invoke-Post }
    'plans' { Invoke-PlanList }
    'help' { Get-Help $PSCommandPath -Detailed }
}
