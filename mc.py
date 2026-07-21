#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["typer>=0.12"]
# ///
"""Message Center CLI: read M365 Message Center posts and push them to Microsoft Planner.

Every Microsoft Graph call is made through `az rest`, so the identity used is whoever is signed in
to the Azure CLI (az login), never an app secret. Reading messages needs a Message Center capable
role (Message Center Reader is enough); writing to Planner needs nothing beyond membership of the
group that owns the plan.

Commands:
  messages   List Message Center posts, filtered by service, category, severity, and time.
  summarise  Produce a markdown summary of the filtered posts.
  post       Create Planner tasks from the filtered posts (one per post, or one rollup task).
  plans      Discover plan ids and buckets for a group, to feed into post.

Run `mc.py <command> --help` for the filters each command takes.
"""

import datetime as dt
import html
import json
import re
import subprocess
from collections import Counter
from typing import List, Optional

import typer

GRAPH = "https://graph.microsoft.com/v1.0"
ADMIN_LINK = "https://admin.microsoft.com/#/MessageCenter/:/messages/{id}"

# Short names for the services people actually say, mapped to substrings matched (case-insensitive)
# against the message's services list. Anything not in this table is used as a raw substring, so
# `--service "power platform"` works without an alias.
SERVICE_ALIASES = {
    "xdr": ["defender xdr", "365 defender"],
    "defender": ["defender"],
    "mde": ["defender for endpoint"],
    "mdo": ["defender for office"],
    "purview": ["purview"],
    "azure": ["azure"],
    "entra": ["entra", "azure ad", "identity"],
    "intune": ["intune"],
    "teams": ["teams"],
    "exchange": ["exchange"],
    "sharepoint": ["sharepoint"],
    "onedrive": ["onedrive"],
    "copilot": ["copilot"],
    "sentinel": ["sentinel"],
    "planner": ["planner"],
    "power": ["power apps", "power automate", "power bi", "power platform"],
}

CATEGORY_ALIASES = {
    "plan": "planForChange",
    "planforchange": "planForChange",
    "stay": "stayInformed",
    "stayinformed": "stayInformed",
    "prevent": "preventOrFixIssue",
    "preventorfixissue": "preventOrFixIssue",
}

app = typer.Typer(
    add_completion=False,
    no_args_is_help=True,
    help=__doc__,
    context_settings={"help_option_names": ["-h", "--help"]},
)


# ---------------------------------------------------------------------------- az plumbing


def az_rest(method: str, url: str, body: Optional[dict] = None, headers: Optional[dict] = None) -> Optional[dict]:
    """Call Microsoft Graph through `az rest` and return the parsed JSON (None for empty replies)."""
    cmd = ["az", "rest", "--method", method, "--url", url, "--output", "json"]
    if body is not None:
        cmd += ["--body", json.dumps(body)]
    for k, v in (headers or {}).items():
        cmd += ["--headers", f"{k}={v}"]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True)
    except FileNotFoundError:
        typer.secho("The Azure CLI (az) is not on PATH. Install it and run az login first.", fg="red", err=True)
        raise typer.Exit(2)
    if proc.returncode != 0:
        err = proc.stderr.strip()
        typer.secho(f"Graph call failed: {method.upper()} {url}", fg="red", err=True)
        typer.secho(err[:2000], err=True)
        if "403" in err or "Forbidden" in err or "Insufficient privileges" in err or "UnknownError" in err:
            typer.secho(
                "\nThis is a permissions problem, not a script problem. Check that:\n"
                "  1. You are logged in to the right tenant: az account show\n"
                "  2. Reading messages: your account holds a Message Center capable admin role\n"
                "     (Message Center Reader is enough).\n"
                "  3. Posting to Planner: you are a member of the group that owns the plan.\n"
                "  4. If the token itself lacks the Graph scopes (decode: az account\n"
                "     get-access-token --resource-type ms-graph, check the scp claim), consent\n"
                "     them once with a scoped login:\n"
                "     az login --scope https://graph.microsoft.com/ServiceMessage.Read.All\n"
                "     az login --scope https://graph.microsoft.com/Tasks.ReadWrite\n"
                "     (.default only returns scopes already consented; it cannot add new ones.)",
                fg="yellow",
                err=True,
            )
        raise typer.Exit(1)
    out = proc.stdout.strip()
    return json.loads(out) if out else None


def graph_get_all(url: str) -> List[dict]:
    """GET a Graph collection, following @odata.nextLink until exhausted."""
    items: List[dict] = []
    while url:
        page = az_rest("get", url) or {}
        items.extend(page.get("value", []))
        url = page.get("@odata.nextLink")
    return items


# ---------------------------------------------------------------------------- filtering


def parse_period(
    day: Optional[str], week: Optional[str], month: Optional[str], year: Optional[str]
) -> Optional[tuple]:
    """Turn exactly one of day/week/month/year into a (start, end, label) UTC window."""
    supplied = [p for p in (day, week, month, year) if p is not None]
    if not supplied:
        return None
    if len(supplied) > 1:
        typer.secho("Use only one of --day, --week, --month, --year.", fg="red", err=True)
        raise typer.Exit(2)

    today = dt.datetime.now(dt.timezone.utc).date()

    if day is not None:
        if day == "today":
            d = today
        elif day == "yesterday":
            d = today - dt.timedelta(days=1)
        else:
            d = dt.date.fromisoformat(day)
        start = dt.datetime.combine(d, dt.time.min, dt.timezone.utc)
        return start, start + dt.timedelta(days=1), f"day {d.isoformat()}"

    if week is not None:
        if week in ("this", "last"):
            anchor = today if week == "this" else today - dt.timedelta(days=7)
            iso = anchor.isocalendar()
            y, w = iso[0], iso[1]
        else:
            m = re.fullmatch(r"(\d{4})-W(\d{1,2})", week)
            if not m:
                typer.secho("Week must be this, last, or ISO form like 2026-W29.", fg="red", err=True)
                raise typer.Exit(2)
            y, w = int(m.group(1)), int(m.group(2))
        monday = dt.date.fromisocalendar(y, w, 1)
        start = dt.datetime.combine(monday, dt.time.min, dt.timezone.utc)
        return start, start + dt.timedelta(days=7), f"week {y}-W{w:02d}"

    if month is not None:
        if month in ("this", "last"):
            anchor = today.replace(day=1)
            if month == "last":
                anchor = (anchor - dt.timedelta(days=1)).replace(day=1)
            y, mo = anchor.year, anchor.month
        else:
            m = re.fullmatch(r"(\d{4})-(\d{1,2})", month)
            if not m:
                typer.secho("Month must be this, last, or ISO form like 2026-07.", fg="red", err=True)
                raise typer.Exit(2)
            y, mo = int(m.group(1)), int(m.group(2))
        start = dt.datetime(y, mo, 1, tzinfo=dt.timezone.utc)
        end = dt.datetime(y + 1, 1, 1, tzinfo=dt.timezone.utc) if mo == 12 else dt.datetime(y, mo + 1, 1, tzinfo=dt.timezone.utc)
        return start, end, f"month {y}-{mo:02d}"

    y = int(year)
    start = dt.datetime(y, 1, 1, tzinfo=dt.timezone.utc)
    return start, dt.datetime(y + 1, 1, 1, tzinfo=dt.timezone.utc), f"year {y}"


def msg_datetime(msg: dict, date_field: str) -> Optional[dt.datetime]:
    raw = msg.get(date_field)
    if not raw:
        return None
    return dt.datetime.fromisoformat(raw.replace("Z", "+00:00"))


def wanted_service(msg: dict, service_terms: List[str]) -> bool:
    if not service_terms:
        return True
    services = " | ".join(msg.get("services") or []).lower()
    for term in service_terms:
        for needle in SERVICE_ALIASES.get(term.lower(), [term.lower()]):
            if needle in services:
                return True
    return False


def filter_messages(
    messages: List[dict],
    services: List[str],
    category: Optional[str],
    severity: Optional[str],
    major_only: bool,
    period: Optional[tuple],
    date_field: str,
) -> List[dict]:
    out = []
    want_category = CATEGORY_ALIASES.get(category.lower()) if category else None
    if category and not want_category:
        typer.secho("Category must be one of: planForChange, stayInformed, preventOrFixIssue.", fg="red", err=True)
        raise typer.Exit(2)
    for m in messages:
        if not wanted_service(m, services):
            continue
        if want_category and m.get("category") != want_category:
            continue
        if severity and (m.get("severity") or "").lower() != severity.lower():
            continue
        if major_only and not m.get("isMajorChange"):
            continue
        if period:
            when = msg_datetime(m, date_field)
            if when is None or not (period[0] <= when < period[1]):
                continue
        out.append(m)
    out.sort(key=lambda m: m.get(date_field) or "", reverse=True)
    return out


def fetch_filtered(services, category, severity, major_only, day, week, month, year, date_field):
    period = parse_period(day, week, month, year)
    messages = graph_get_all(f"{GRAPH}/admin/serviceAnnouncement/messages?$top=100")
    return filter_messages(messages, services, category, severity, major_only, period, date_field), period


def strip_html(text: str, cap: int = 2000) -> str:
    text = re.sub(r"<(script|style)[^>]*>.*?</\1>", " ", text, flags=re.S | re.I)
    text = re.sub(r"<br\s*/?>|</p>|</li>", "\n", text, flags=re.I)
    text = re.sub(r"<[^>]+>", " ", text)
    text = html.unescape(text)
    text = re.sub(r"[ \t]+", " ", text)
    text = re.sub(r"\n\s*\n\s*", "\n\n", text).strip()
    return text[:cap] + (" ..." if len(text) > cap else "")


def build_summary(messages: List[dict], period, services, category, severity, date_field) -> str:
    label_bits = []
    if period:
        label_bits.append(period[2])
    if services:
        label_bits.append("services: " + ", ".join(services))
    if category:
        label_bits.append(f"category: {category}")
    if severity:
        label_bits.append(f"severity: {severity}")
    label = "; ".join(label_bits) if label_bits else "all messages"

    sev = Counter((m.get("severity") or "normal") for m in messages)
    lines = [
        f"# Message Center summary ({label})",
        "",
        f"Total: {len(messages)} messages "
        f"({sev.get('critical', 0)} critical, {sev.get('high', 0)} high, {sev.get('normal', 0)} normal)",
        "",
        "## By service",
    ]
    by_service = Counter(s for m in messages for s in (m.get("services") or ["(none)"]))
    for name, count in by_service.most_common():
        lines.append(f"- {name}: {count}")

    lines += ["", "## By category"]
    for name, count in Counter(m.get("category") or "(none)" for m in messages).most_common():
        lines.append(f"- {name}: {count}")

    action = [m for m in messages if m.get("actionRequiredByDateTime")]
    if action:
        lines += ["", "## Action required"]
        for m in sorted(action, key=lambda m: m["actionRequiredByDateTime"]):
            due = m["actionRequiredByDateTime"][:10]
            lines.append(f"- {m['id']} due {due}: {m.get('title', '')}")

    lines += ["", "## Messages"]
    for m in messages:
        when = (m.get(date_field) or "")[:10]
        svc = ", ".join(m.get("services") or [])
        lines.append(f"- {m['id']} {when} [{svc}] {m.get('title', '')}")
    return "\n".join(lines)


# Shared filter options, spelled once.
OPT_SERVICE = typer.Option(None, "--service", "-s", help="Service filter, repeatable. Short names (xdr, purview, azure, entra, intune, teams ...) or any substring of the service name.")
OPT_CATEGORY = typer.Option(None, "--category", "-c", help="planForChange, stayInformed, or preventOrFixIssue (plan/stay/prevent also accepted).")
OPT_SEVERITY = typer.Option(None, "--severity", help="normal, high, or critical.")
OPT_MAJOR = typer.Option(False, "--major", help="Only major-change messages.")
OPT_DAY = typer.Option(None, "--day", help="A date (2026-07-20), today, or yesterday.")
OPT_WEEK = typer.Option(None, "--week", help="An ISO week (2026-W29), this, or last.")
OPT_MONTH = typer.Option(None, "--month", help="A month (2026-07), this, or last.")
OPT_YEAR = typer.Option(None, "--year", help="A year (2026).")
OPT_DATE_FIELD = typer.Option("lastModifiedDateTime", "--date-field", help="Which timestamp the time filters compare against: lastModifiedDateTime or startDateTime.")


# ---------------------------------------------------------------------------- commands


@app.command()
def messages(
    service: List[str] = OPT_SERVICE,
    category: Optional[str] = OPT_CATEGORY,
    severity: Optional[str] = OPT_SEVERITY,
    major: bool = OPT_MAJOR,
    day: Optional[str] = OPT_DAY,
    week: Optional[str] = OPT_WEEK,
    month: Optional[str] = OPT_MONTH,
    year: Optional[str] = OPT_YEAR,
    date_field: str = OPT_DATE_FIELD,
    output: str = typer.Option("table", "--output", "-o", help="table, json, or ids."),
    limit: int = typer.Option(0, "--limit", help="Show at most this many rows (0 = all)."),
):
    """List Message Center posts with the chosen filters."""
    msgs, _ = fetch_filtered(service, category, severity, major, day, week, month, year, date_field)
    if limit:
        msgs = msgs[:limit]
    if output == "json":
        typer.echo(json.dumps(msgs, indent=2))
        return
    if output == "ids":
        for m in msgs:
            typer.echo(m["id"])
        return
    if not msgs:
        typer.secho("No messages matched.", fg="yellow")
        return
    typer.echo(f"{'ID':<10} {'SEV':<9} {'MODIFIED':<11} {'SERVICES':<32} TITLE")
    for m in msgs:
        svc = ", ".join(m.get("services") or [])
        typer.echo(
            f"{m['id']:<10} {(m.get('severity') or ''):<9} {(m.get(date_field) or '')[:10]:<11} "
            f"{svc[:31]:<32} {(m.get('title') or '')[:70]}"
        )
    typer.secho(f"\n{len(msgs)} message(s).", fg="green")


@app.command()
def summarise(
    service: List[str] = OPT_SERVICE,
    category: Optional[str] = OPT_CATEGORY,
    severity: Optional[str] = OPT_SEVERITY,
    major: bool = OPT_MAJOR,
    day: Optional[str] = OPT_DAY,
    week: Optional[str] = OPT_WEEK,
    month: Optional[str] = OPT_MONTH,
    year: Optional[str] = OPT_YEAR,
    date_field: str = OPT_DATE_FIELD,
    out: Optional[str] = typer.Option(None, "--out", help="Write the markdown to this file instead of stdout."),
):
    """Summarise the filtered posts as markdown (counts by service, category, action-required list)."""
    msgs, period = fetch_filtered(service, category, severity, major, day, week, month, year, date_field)
    text = build_summary(msgs, period, service, category, severity, date_field)
    if out:
        with open(out, "w") as fh:
            fh.write(text + "\n")
        typer.secho(f"Wrote {out} ({len(msgs)} messages).", fg="green")
    else:
        typer.echo(text)


@app.command()
def plans(
    group_name: str = typer.Option(..., "--group-name", "-g", help="Display name of the M365 group that owns the plan."),
    buckets: bool = typer.Option(False, "--buckets", help="Also list each plan's buckets."),
):
    """Find plan ids (and optionally bucket ids) for a group, to feed into post."""
    safe = group_name.replace("'", "''")
    groups = graph_get_all(f"{GRAPH}/groups?$filter=displayName eq '{safe}'&$select=id,displayName")
    if not groups:
        typer.secho(f"No group named '{group_name}' found (or no read access to it).", fg="red", err=True)
        raise typer.Exit(1)
    for g in groups:
        typer.secho(f"Group: {g['displayName']} ({g['id']})", fg="cyan")
        for p in graph_get_all(f"{GRAPH}/groups/{g['id']}/planner/plans"):
            typer.echo(f"  plan: {p['title']}  id: {p['id']}")
            if buckets:
                for b in graph_get_all(f"{GRAPH}/planner/plans/{p['id']}/buckets"):
                    typer.echo(f"    bucket: {b['name']}  id: {b['id']}")


@app.command()
def post(
    plan_id: str = typer.Option(..., "--plan-id", help="Planner plan id (find it with the plans command)."),
    bucket_name: str = typer.Option("To be discussed", "--bucket-name", help="Bucket (board column) to post into; created if missing."),
    rollup: bool = typer.Option(False, "--rollup", help="Create ONE task holding the whole summary instead of one task per message."),
    dry_run: bool = typer.Option(False, "--dry-run", help="Show what would be created without writing anything."),
    service: List[str] = OPT_SERVICE,
    category: Optional[str] = OPT_CATEGORY,
    severity: Optional[str] = OPT_SEVERITY,
    major: bool = OPT_MAJOR,
    day: Optional[str] = OPT_DAY,
    week: Optional[str] = OPT_WEEK,
    month: Optional[str] = OPT_MONTH,
    year: Optional[str] = OPT_YEAR,
    date_field: str = OPT_DATE_FIELD,
):
    """Create Planner tasks from the filtered posts. Re-runs are safe: existing tasks are skipped."""
    msgs, period = fetch_filtered(service, category, severity, major, day, week, month, year, date_field)
    if not msgs:
        typer.secho("No messages matched; nothing to post.", fg="yellow")
        return

    existing_titles = [t.get("title") or "" for t in graph_get_all(f"{GRAPH}/planner/plans/{plan_id}/tasks")]

    all_buckets = graph_get_all(f"{GRAPH}/planner/plans/{plan_id}/buckets")
    bucket = next((b for b in all_buckets if b["name"].lower() == bucket_name.lower()), None)
    if bucket is None:
        if dry_run:
            typer.echo(f"[dry-run] would create bucket '{bucket_name}'")
            bucket = {"id": "(new)"}
        else:
            bucket = az_rest("post", f"{GRAPH}/planner/buckets", body={"name": bucket_name, "planId": plan_id, "orderHint": " !"})
            typer.secho(f"Created bucket '{bucket_name}'.", fg="green")

    def create_task(title: str, description: str, due: Optional[str]):
        if dry_run:
            typer.echo(f"[dry-run] would create task: {title}" + (f" (due {due[:10]})" if due else ""))
            return
        body = {"planId": plan_id, "bucketId": bucket["id"], "title": title}
        if due:
            body["dueDateTime"] = due
        task = az_rest("post", f"{GRAPH}/planner/tasks", body=body)
        details = az_rest("get", f"{GRAPH}/planner/tasks/{task['id']}/details")
        az_rest(
            "patch",
            f"{GRAPH}/planner/tasks/{task['id']}/details",
            body={"description": description, "previewType": "description"},
            headers={"If-Match": details["@odata.etag"]},
        )
        typer.secho(f"Created: {title}", fg="green")

    if rollup:
        label = period[2] if period else dt.date.today().isoformat()
        title = f"Message Center rollup: {label} ({len(msgs)} messages)"
        if any(title == t for t in existing_titles):
            typer.secho(f"Rollup task already exists, skipping: {title}", fg="yellow")
            return
        create_task(title, build_summary(msgs, period, service, category, severity, date_field)[:20000], None)
        return

    created = skipped = 0
    for m in msgs:
        title = f"{m['id']}: {(m.get('title') or '').strip()}"[:255]
        if any(t.startswith(m["id"]) for t in existing_titles):
            skipped += 1
            continue
        body_text = strip_html((m.get("body") or {}).get("content") or "")
        description = (
            f"Services: {', '.join(m.get('services') or [])}\n"
            f"Category: {m.get('category')}  Severity: {m.get('severity')}  Major change: {bool(m.get('isMajorChange'))}\n"
            f"Last modified: {(m.get('lastModifiedDateTime') or '')[:10]}\n"
            f"Admin center: {ADMIN_LINK.format(id=m['id'])}\n\n{body_text}"
        )
        create_task(title, description, m.get("actionRequiredByDateTime"))
        created += 1
    typer.secho(f"Done: {created} created, {skipped} already present.", fg="green")


if __name__ == "__main__":
    app()
