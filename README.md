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
  `uv run mc.py` resolves its dependencies on the fly.
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
  Access policies block device-code sign-in (common in banks, since attackers love that flow): the
  same client and scopes, but a normal browser sign-in with a localhost redirect. Needs a browser
  reachable from where the script runs.
- The `plans` command additionally needs `Group.Read.All`, which many tenants gate behind admin
  consent. If that is refused, skip `plans`: the plan id is right there in the Planner board URL
  (the value after `/plan/` or the `planId` query parameter), and nothing else needs group reads.

## Filters (shared by messages, summarise, and post)

- `--service / -s` (repeatable): short names `xdr`, `purview`, `azure`, `entra`, `intune`, `teams`,
  `exchange`, `sharepoint`, `copilot`, `sentinel`, and more, or any substring of the service name.
- `--category / -c`: `planForChange`, `stayInformed`, `preventOrFixIssue` (or `plan`/`stay`/`prevent`).
- `--severity`: `normal`, `high`, `critical`. `--major`: major changes only.
- Time (pick one): `--day 2026-07-20|today|yesterday`, `--week 2026-W29|this|last`,
  `--month 2026-07|this|last`, `--year 2026`.
- `--date-field`: which timestamp the time filters compare against (`lastModifiedDateTime` by
  default, or `startDateTime`).

## Two engines, one tool

The repo carries the same CLI twice: **`mc.py`** (Python, Typer) and **`mc.ps1`** (PowerShell 7,
zero module dependencies, auth flows included), for machines where Python is not an option. Same
commands, same filters, same behaviour, same token cache location conventions; only the argument
style differs:

| Python | PowerShell |
|---|---|
| `uv run mc.py messages -s xdr --week this` | `./mc.ps1 messages -Service xdr -Week this` |
| `uv run mc.py messages -s purview -s azure --month last --out-csv m.csv` | `./mc.ps1 messages -Service purview,azure -Month last -OutCsv m.csv` |
| `uv run mc.py summarise --major --month this --out summary.md` | `./mc.ps1 summarise -Major -Month this -OutFile summary.md` |
| `uv run mc.py post --plan-id <id> --week last --dry-run` | `./mc.ps1 post -PlanId <id> -Week last -DryRun` |
| `uv run mc.py plans --group-name "Team" --buckets` | `./mc.ps1 plans -GroupName "Team" -Buckets` |
| `uv run mc.py --auth device messages ...` | `./mc.ps1 messages ... -Auth device` |

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
uv run mc.py plans --group-name "Platform Team" --buckets   # note the plan id
uv run mc.py post --plan-id <planId> --week last --dry-run  # preview first
uv run mc.py post --plan-id <planId> --week last            # then for real
```

Care about specific workloads only? Filters stack:

```bash
uv run mc.py post --plan-id <planId> --week last -s xdr -s purview
```

### What changed, quickly

```bash
uv run mc.py messages -s xdr --week this                 # XDR movement this week
uv run mc.py messages -s azure --month this --major      # major Azure changes this month
uv run mc.py messages --severity critical --year 2026    # every critical post this year
uv run mc.py messages -c prevent --day today             # fix-or-prevent issues landed today
uv run mc.py messages -s "power platform" --month last   # no alias needed, substrings work
```

### Reports and exports

```bash
# Markdown rollup of last month, one file per team briefing
uv run mc.py summarise --month last --out july.md

# The action-required list is the part people actually miss: it is a section of every summary
uv run mc.py summarise -s purview --year 2026

# CSV for Excel or Power BI (services, dates, links, and a body extract per row)
uv run mc.py messages -s purview -s azure --month last --out-csv messages.csv

# Or a single Planner task holding the whole month's summary, instead of one per post
uv run mc.py post --plan-id <planId> --month last --rollup
```

### Plumbing

```bash
uv run mc.py messages --week this -o json   # raw Graph objects, for jq and friends
uv run mc.py messages --week this -o ids    # just the MC ids, one per line
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
