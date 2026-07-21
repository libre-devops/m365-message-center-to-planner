<div align="center">
  <a href="https://libredevops.org">
    <picture>
      <source media="(prefers-color-scheme: dark)" srcset="https://libredevops.org/assets/libre-devops-white.png">
      <img alt="Libre DevOps" src="https://libredevops.org/assets/libre-devops-black.png" width="300">
    </picture>
  </a>
</div>

# M365 Message Center to Planner

A quick helper that gets Microsoft 365 Message Center posts onto a Microsoft Planner board, into a
column named **To be discussed** by default.

[![CI](https://github.com/libre-devops/m365-message-center-to-planner/actions/workflows/ci.yml/badge.svg)](https://github.com/libre-devops/m365-message-center-to-planner/actions/workflows/ci.yml)
[![License](https://img.shields.io/github/license/libre-devops/m365-message-center-to-planner)](./LICENSE)

---

## Overview

You should probably automate this with a Logic App, but this is for lazy quick tooling. And now
there IS the Logic App: see [The Logic App](#the-logic-app-the-real-automation) below. The repo
splits accordingly: [`terraform/`](./terraform) is the automation, and the scripts live under
[`debug/python/`](./debug/python) and [`debug/powershell/`](./debug/powershell) as the ad-hoc,
debugging, and one-off-export companions they were always meant to be.

A single-file Python (Typer) CLI that reads the Message Center and pushes filtered posts to
Planner, so service changes actually get discussed instead of rotting in the admin center. Every
Graph call goes through `az rest`, meaning the identity used is whoever is signed in to the Azure
CLI: no app registration, no secrets, and your existing read access is exactly what the script gets.

- `messages` lists posts filtered by service (XDR, Purview, Azure, ...), category, severity, and a
  day, week, month, or year window.
- `summarise` turns the same filters into a markdown rollup (counts by service and category, plus an
  action-required list with due dates).
- `post` creates one Planner task per post in the **To be discussed** column (or one rollup task
  with `--rollup`), with the admin center deep link and body extract in the description and any
  Microsoft action-required date as the due date. Re-runs skip tasks that already exist, so it can
  run on a schedule.
- `plans` finds the plan and bucket ids for a group, to feed into `post`.

## Requirements

- [`uv`](https://github.com/astral-sh/uv): the script carries inline dependency metadata, so
  `uv run debug/python/mc.py` resolves its dependencies on the fly.
- Reading messages: a Message Center capable admin role on your account (Message Center Reader is
  enough; Global Reader also works).
- Posting to Planner: membership of the M365 group that owns the target plan.

## Signing in (two modes, both are you)

Both modes act as your signed-in user; there is no app registration and no secret anywhere.

- **`--auth az`** (the default) rides the Azure CLI login through `az rest`. It only works if the
  cached az token already carries the Graph scopes, which in practice it rarely does: the Azure CLI
  is a Microsoft first-party application, and Microsoft only lets first-party apps request Graph
  scopes it has preauthorized for them. `ServiceMessage.Read.All` and `Tasks.ReadWrite` are not on
  the Azure CLI's list, so `az login --scope ...` for them dies with **AADSTS65002** in any tenant
  (caught live; that error is the platform saying no, not your admins).
- **`--auth device`** (or `export MC_AUTH=device`, which the justfile recipes pick up) is the
  reliable mode: a device-code sign-in through the **Microsoft Graph Command Line Tools** public
  client, the same first-party app `Connect-MgGraph` uses, which IS allowed to request these scopes.
  First run prints a code and a URL, you approve it in a browser as yourself, and the token (with
  refresh) is cached at `~/.config/m365-mc-planner/token-cache.json` so later runs are silent. Pass
  `--tenant <id or domain>` (or `MC_TENANT`) to pin the tenant. Your tenant's consent policy still
  applies: if user consent is restricted, the sign-in shows an admin approval flow instead.
- **`--auth interactive`** (or `MC_AUTH=interactive`) is the fallback for tenants whose Conditional
  Access policies block device-code sign-in (common in hardened tenants, since attackers love that flow): the
  same client and scopes, but a normal browser sign-in with a localhost redirect. Needs a browser
  reachable from where the script runs.
- **AADSTS50105** ("configured to block users unless specifically granted access") means the tenant
  requires per-user assignment on the Microsoft Graph Command Line Tools enterprise app, and the
  signed-in user is not assigned. That gate is per client app, which is why other Graph tooling can
  work while this refuses. Either request assignment to that app (MyApps or an admin), or point the
  script at a public client the tenant does permit with `--client-id` / `-ClientId` /
  `MC_CLIENT_ID`: any app registration with "allow public client flows" on, a `http://localhost`
  redirect URI, and delegated `ServiceMessage.Read.All` + `Tasks.ReadWrite`. No secret is involved
  either way; the sign-in is still you.
- `plans` with no arguments lists YOUR plans (via `/me/planner/plans`), which is the only way to
  find roster plans: the personal boards new Planner creates under My plans have no M365 group
  behind them, so the `-GroupName`/`--group-name` lookup cannot see them (caught live). The sign-in
  deliberately requests only `ServiceMessage.Read.All` and `Tasks.ReadWrite`: `Group.Read.All`
  (needed only by the group-name lookup) is admin-consent-gated in most corporate tenants, and
  consent is all-or-nothing per sign-in, so requesting it could block everything else. The group
  lookup will therefore 403 in device/interactive mode unless your admins have consented that scope
  to the Microsoft Graph Command Line Tools app; use the no-argument form or take the plan id from
  the Planner board URL.

## Filters (shared by messages, summarise, and post)

- `--service / -s` (repeatable): short names `xdr`, `purview`, `azure`, `entra`, `intune`, `teams`,
  `exchange`, `sharepoint`, `copilot`, `sentinel`, and more, or any substring of the service name.
- `--category / -c`: `planForChange`, `stayInformed`, `preventOrFixIssue` (or `plan`/`stay`/`prevent`).
- `--severity`: `normal`, `high`, `critical`. `--major`: major changes only.
- Time (pick one): `--day 2026-07-20|today|yesterday`, `--week 2026-W29|this|last`,
  `--month 2026-07|this|last`, `--year 2026`.
- `--date-field`: which timestamp the time filters compare against (`lastModifiedDateTime` by
  default, or `startDateTime`).

## The Logic App (the real automation)

[`terraform/`](./terraform) deploys the production version: two consumption Logic App workflows
built from the Libre DevOps registry modules (`rg`, `tags`, `logic-app-workflow`), each with a
system-assigned managed identity calling Microsoft Graph over raw HTTP. No API connections, no app
registrations, no secrets anywhere in the design; the only credentials that exist are the managed
identities themselves.

- **`logic-...-mc-001`, daily at 07:00 UTC**: fetches messages whose `lastModifiedDateTime` falls
  inside the lookback window, and raises ONE Planner ticket per message that has no ticket yet
  (dedupe by the MC id prefix in the task title, same contract as the scripts, so scripts and
  workflow can share a board without double-posting). Tickets carry the services, category,
  severity, admin center deep link, and Microsoft's action-required date as the due date.
- **`logic-...-mc-002`, monthly on the 1st at 06:00 UTC**: raises a single rollup ticket titled
  `Message Center rollup: <yyyy-MM> (N messages)` for the previous calendar month, with a one line
  per message summary in the description. The title doubles as the dedupe key, so reruns inside a
  month are no-ops.

Both proven live: the daily sync processed a 100-message backlog app-only without a single failure
(including against a roster plan, which application-permission Planner writes do support), and the
monthly rollup landed alongside it.

### Deploy

```bash
cd terraform
az login                                                  # an account able to create the rg and workflows
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)
terraform init
terraform apply -var plan_id=<planId> -var bucket_id=<bucketId>
```

`plan_id` and `bucket_id` come from `plans -Buckets` in either script (or the Planner board URL).
State is local and gitignored; this is a personal-tenant stack, not a shared pipeline.

### Grant the identities Graph access (one-time, admin)

The workflows' identities need two Graph APPLICATION roles: `ServiceMessage.Read.All` (read the
Message Center) and `Tasks.ReadWrite.All` (write Planner). The stack supports two routes; pick one
and stay with it (a grant created one way makes the other way report it as already existing).

**Terraform, the default.** The stack manages the grants itself through the
[`role-assignment`](https://registry.terraform.io/modules/libre-devops/role-assignment/azuread)
azuread module (4.2.0+), so one apply by someone holding `AppRoleAssignment.ReadWrite.All` (Global
Administrator works) deploys the workflows AND consents their permissions. The grants live in
state, appear in every plan, and `terraform destroy` removes them with the identities:

```bash
terraform apply -var plan_id=<planId> -var bucket_id=<bucketId>
```

Under the hood it is one module block, names in, GUIDs never:

```hcl
module "graph_grants" {
  source  = "libre-devops/role-assignment/azuread"
  version = "~> 4.2"

  graph_app_role_grants = {
    for name, identity in module.logic_app_workflow.identities : name => {
      principal_object_id = identity.principal_id
      role_names          = ["ServiceMessage.Read.All", "Tasks.ReadWrite.All"]
    }
  }
}
```

**Azure CLI, the escape hatch.** When the person applying Terraform cannot hold
`AppRoleAssignment.ReadWrite.All`, deploy without the grants and hand the printed commands to a
Global Administrator:

```bash
terraform apply -var plan_id=<planId> -var bucket_id=<bucketId> -var manage_graph_grants=false
terraform output grant_commands
```

Each printed command is a pair of Graph appRoleAssignments posts for one identity, of the form:

```bash
az rest --method POST \
  --url https://graph.microsoft.com/v1.0/servicePrincipals/<workflow principal id>/appRoleAssignments \
  --body '{"principalId":"<workflow principal id>","resourceId":"<tenant Graph SP object id>","appRoleId":"<app role id>"}'
```

### Run it now instead of waiting for the timers

```bash
az rest --method POST --url "https://management.azure.com<workflowId>/triggers/<triggerName>/run?api-version=2016-06-01"
# trigger names: Recurrence_-_Every_day_at_07_00_UTC and Recurrence_-_First_of_the_month_at_06_00_UTC
```

### Tuning and costs

`daily_lookback_days` defaults to 2, and the default matters: Message Center constantly re-touches
old posts, so a wide `lastModifiedDateTime` window is close to the entire active feed (a 30-day
window pulled ~100 messages in testing) and means a wall of tickets on first run. The dedupe makes
any overlap safe, so keep the window small and let daily runs accumulate. Consumption workflows
bill per action execution; this design costs pennies per month. `terraform destroy` removes
everything, including the identities (and with them the grants).

## Two engines, one tool

The repo carries the same CLI twice: **`debug/python/mc.py`** (Python, Typer) and **`debug/powershell/mc.ps1`** (PowerShell 7,
zero module dependencies, auth flows included), for machines where Python is not an option. Same
commands, same filters, same behaviour, same token cache location conventions; only the argument
style differs:

| Python | PowerShell |
|---|---|
| `uv run debug/python/mc.py messages -s xdr --week this` | `./debug/powershell/mc.ps1 messages -Service xdr -Week this` |
| `uv run debug/python/mc.py messages -s purview -s azure --month last --out-csv m.csv` | `./debug/powershell/mc.ps1 messages -Service purview,azure -Month last -OutCsv m.csv` |
| `uv run debug/python/mc.py summarise --major --month this --out summary.md` | `./debug/powershell/mc.ps1 summarise -Major -Month this -OutFile summary.md` |
| `uv run debug/python/mc.py post --plan-id <id> --week last --dry-run` | `./debug/powershell/mc.ps1 post -PlanId <id> -Week last -DryRun` |
| `uv run debug/python/mc.py plans --buckets` | `./debug/powershell/mc.ps1 plans -Buckets` |
| `uv run debug/python/mc.py plans --group-name "Team" --buckets` | `./debug/powershell/mc.ps1 plans -GroupName "Team" -Buckets` |
| `uv run debug/python/mc.py --auth device messages ...` | `./debug/powershell/mc.ps1 messages ... -Auth device` |

Both honour `MC_AUTH`, `MC_TENANT`, and `MC_PLAN_ID` from the environment, so a `.env`/exports
setup drives either engine unchanged. The examples below use the Python spelling; transpose per the
table for PowerShell.

## Usage

Prefix everything with `uv run` (dependencies resolve inline), or use the justfile below.

### The Monday triage

Find your board once, then put last week's posts on it as tasks, one per post, in the
**To be discussed** column. Re-runs only add what is new, so this is safe as a weekly habit or a
scheduled job:

```bash
uv run debug/python/mc.py plans --group-name "Platform Team" --buckets   # note the plan id
uv run debug/python/mc.py post --plan-id <planId> --week last --dry-run  # preview first
uv run debug/python/mc.py post --plan-id <planId> --week last            # then for real
```

Care about specific workloads only? Filters stack:

```bash
uv run debug/python/mc.py post --plan-id <planId> --week last -s xdr -s purview
```

### What changed, quickly

```bash
uv run debug/python/mc.py messages -s xdr --week this                 # XDR movement this week
uv run debug/python/mc.py messages -s azure --month this --major      # major Azure changes this month
uv run debug/python/mc.py messages --severity critical --year 2026    # every critical post this year
uv run debug/python/mc.py messages -c prevent --day today             # fix-or-prevent issues landed today
uv run debug/python/mc.py messages -s "power platform" --month last   # no alias needed, substrings work
```

### Reports and exports

```bash
# Markdown rollup of last month, one file per team briefing
uv run debug/python/mc.py summarise --month last --out july.md

# The action-required list is the part people actually miss: it is a section of every summary
uv run debug/python/mc.py summarise -s purview --year 2026

# CSV for Excel or Power BI (services, dates, links, and a body extract per row)
uv run debug/python/mc.py messages -s purview -s azure --month last --out-csv messages.csv

# Or a single Planner task holding the whole month's summary, instead of one per post
uv run debug/python/mc.py post --plan-id <planId> --month last --rollup
```

### Plumbing

```bash
uv run debug/python/mc.py messages --week this -o json   # raw Graph objects, for jq and friends
uv run debug/python/mc.py messages --week this -o ids    # just the MC ids, one per line
```

## Windows quick start (no just, PowerShell only)

The script needs PowerShell 7 (`pwsh`); from Windows PowerShell 5.1, prefix commands with
`pwsh -NoProfile -File`. Set the environment once per session (or in `$PROFILE`):

```powershell
$env:MC_AUTH   = 'device'        # or 'interactive' if Conditional Access blocks device code
$env:MC_TENANT = '<tenant id or domain>'
$env:MC_PLAN_ID = '<planId>'     # once known; post then needs no -PlanId
```

### Signing in with device auth

Device auth is selected with `-Auth device` on any command (or once via `$env:MC_AUTH = 'device'`,
which every command then inherits; there is no standalone `-Device` flag). The first run prints
something like:

```
To sign in, use a web browser to open the page https://microsoft.com/devicelogin
and enter the code ABCD1234 to authenticate.
```

Open that page anywhere (your phone works), enter the code, approve as yourself, and the command
continues on its own. The token, including a refresh token, is cached at
`~/.config/m365-mc-planner/token-cache-ps.json`, so every later run in any window is silent until
the refresh token expires; you only ever see the code prompt again after that. If the sign-in is
rejected rather than completed, that is Conditional Access blocking device code: switch to
`-Auth interactive` (a normal browser sign-in on this machine) and everything else stays the same.

### Listing and filtering

```powershell
.\debug\powershell\mc.ps1 messages -Service xdr -Week this
.\debug\powershell\mc.ps1 messages -Service purview,azure -Month last
.\debug\powershell\mc.ps1 messages -Severity critical -Year 2026
.\debug\powershell\mc.ps1 messages -Category prevent -Day today
.\debug\powershell\mc.ps1 messages -Major -Month this
.\debug\powershell\mc.ps1 messages -Service "power platform" -Month last     # raw substring, no alias needed
.\debug\powershell\mc.ps1 messages -Service xdr -Week this -Auth device      # auth chosen inline instead of MC_AUTH
```

### Exports and summaries

```powershell
.\debug\powershell\mc.ps1 messages -Service purview,azure -Month last -OutCsv messages.csv
.\debug\powershell\mc.ps1 messages -Service xdr -Week this -Output json      # raw Graph objects
.\debug\powershell\mc.ps1 messages -Service xdr -Week this -Output ids       # just MC ids, one per line
.\debug\powershell\mc.ps1 summarise -Month last -OutFile july.md
.\debug\powershell\mc.ps1 summarise -Major -Month this                        # to the console
```

### Posting to the board, and what -DryRun does

`-DryRun` runs the entire command for real EXCEPT the writes: it reads the messages, reads the
plan's existing tasks and buckets, applies the dedupe, then prints exactly what it WOULD create
(`[dry-run] would create bucket ...`, `[dry-run] would create task: MC123456: ...`) and creates
nothing. Nothing in Planner changes, so it is the safe way to preview a filter before committing,
and a dry run followed by the same command without `-DryRun` produces exactly what the preview
showed.

```powershell
.\debug\powershell\mc.ps1 plans -Buckets                                      # YOUR plans incl. roster boards (My plans)
.\debug\powershell\mc.ps1 plans -GroupName "Platform Team" -Buckets           # a group's plans (needs Group.Read.All)
.\debug\powershell\mc.ps1 post -Week last -DryRun                             # preview: prints, writes nothing
.\debug\powershell\mc.ps1 post -Week last                                     # one task per post into "To be discussed"
.\debug\powershell\mc.ps1 post -Service xdr,purview -Week last                # scoped to specific services
.\debug\powershell\mc.ps1 post -Month last -Rollup                            # one summary task instead of one per post
.\debug\powershell\mc.ps1 post -Week last -BucketName "Radar"                 # a different column
.\debug\powershell\mc.ps1 post -PlanId <planId> -Week last                    # plan id inline instead of MC_PLAN_ID
```

## Run it with just

The justfile wraps the common runs. Set `MC_PLAN_ID` once (exported, or in a gitignored `.env`
next to the justfile) and the posting recipes need no arguments at all:

```bash
just plans "Platform Team"        # find the plan id, put it in .env as MC_PLAN_ID=<id>
just triage-dry                   # preview the Monday run
just triage                       # last week's posts onto the board
just triage -s xdr -s purview     # the same, XDR and Purview only
just month-rollup                 # one task summarising last month
just messages -s azure --week this
just summarise --major --month this
just csv xdr.csv -s xdr --week this
just ps messages -Service xdr -Week this   # the PowerShell twin, PS parameter style
just check                        # lint both engines plus the same smoke CI runs
```

## Behaviour worth knowing

- `post` is idempotent: a task whose title starts with the message id (for example `MC123456`)
  already existing in the plan is skipped, so a scheduled re-run only adds what is new.
- The **To be discussed** bucket is created on first use if the plan lacks it; point `--bucket-name`
  elsewhere to use a different column.
- Per-message tasks carry the services, category, severity, admin center deep link, and a
  plain-text extract of the message body in the task description; `actionRequiredByDateTime`
  becomes the task due date when Microsoft set one.
- The messages list is fetched in full (paged) and filtered locally, so combining filters never
  misses posts that Graph-side filtering would.
- `--out-csv` on `messages` writes the filtered set as CSV (utf-8 with BOM, so Excel opens it
  cleanly): id, title, category, severity, major-change flag, services, tags, the four timestamps,
  the admin center deep link, and a plain-text body extract.
