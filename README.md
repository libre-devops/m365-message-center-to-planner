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

```bash
# Everything Defender XDR touched this week
uv run mc.py messages -s xdr --week this

# All Purview and Azure messages last month, as JSON
uv run mc.py messages -s purview -s azure --month last -o json

# Markdown summary of this month's major changes
uv run mc.py summarise --major --month this --out summary.md

# Find the plan and bucket ids for your team's board
uv run mc.py plans --group-name "Platform Team" --buckets

# One task per critical message this week, into the To be discussed column
uv run mc.py post --plan-id <planId> --severity critical --week this

# A single rollup task holding the whole month's XDR summary
uv run mc.py post --plan-id <planId> -s xdr --month this --rollup

# See what would be created first
uv run mc.py post --plan-id <planId> --week this --dry-run
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
