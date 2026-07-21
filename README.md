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

- Azure CLI, signed in to the tenant: `az login` (check with `az account show`).
- [`uv`](https://github.com/astral-sh/uv): the script carries inline dependency metadata, so
  `uv run mc.py` resolves Typer on the fly. (Plain `python mc.py` also works if Typer is installed.)
- Reading messages: a Message Center capable admin role on your account (Message Center Reader is
  enough; Global Reader also works).
- Posting to Planner: membership of the M365 group that owns the target plan.
- If Graph returns 403 despite a valid role, the Azure CLI token is missing the delegated scopes
  (decode it with `az account get-access-token --resource-type ms-graph` and inspect the `scp`
  claim). Consent them once with a scoped login, after which every later `az rest` call carries
  them:

  ```bash
  az login --scope https://graph.microsoft.com/ServiceMessage.Read.All   # reading messages
  az login --scope https://graph.microsoft.com/Tasks.ReadWrite           # posting to Planner
  ```

  `.default` only returns scopes already consented, so it cannot add these. Tenants that require
  admin consent for user grants will pop an approval flow instead; and some tenants restrict the
  Azure CLI application's Graph access entirely, which is a tenant policy conversation rather than
  a script fix.

## Filters (shared by messages, summarise, and post)

- `--service / -s` (repeatable): short names `xdr`, `purview`, `azure`, `entra`, `intune`, `teams`,
  `exchange`, `sharepoint`, `copilot`, `sentinel`, and more, or any substring of the service name.
- `--category / -c`: `planForChange`, `stayInformed`, `preventOrFixIssue` (or `plan`/`stay`/`prevent`).
- `--severity`: `normal`, `high`, `critical`. `--major`: major changes only.
- Time (pick one): `--day 2026-07-20|today|yesterday`, `--week 2026-W29|this|last`,
  `--month 2026-07|this|last`, `--year 2026`.
- `--date-field`: which timestamp the time filters compare against (`lastModifiedDateTime` by
  default, or `startDateTime`).

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
just check                        # lint plus the same smoke CI runs
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
