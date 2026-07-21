# Recipes for the Message Center to Planner helper. `just` on its own lists them.
#
# The posting recipes need a Planner plan id. Set it once and forget it: export MC_PLAN_ID in your
# shell, or drop `MC_PLAN_ID=<id>` in a local .env file next to this justfile (gitignored, loaded
# automatically). Find the id with: just plans "Your Team Name"

set dotenv-load

plan_id := env_var_or_default("MC_PLAN_ID", "")

default:
    @just --list

# Pass anything straight through to the Python CLI, e.g. just mc messages -s xdr --week this
mc *args:
    uv run mc.py {{ args }}

# The PowerShell twin, for machines without Python. PowerShell parameter style,
# e.g. just ps messages -Service xdr -Week this
ps *args:
    pwsh -NoProfile -File ./mc.ps1 {{ args }}

# List posts. Filters append, e.g. just messages -s purview --month last
messages *args:
    uv run mc.py messages {{ args }}

# Markdown summary to stdout. Filters append, e.g. just summarise --major --month this
summarise *args:
    uv run mc.py summarise {{ args }}

# Export filtered posts to CSV, e.g. just csv xdr.csv -s xdr --week this
csv out *args:
    uv run mc.py messages --out-csv {{ out }} {{ args }}

# Find plan and bucket ids for a group, e.g. just plans "Platform Team"
plans group:
    uv run mc.py plans --group-name "{{ group }}" --buckets

# The Monday run: last week's posts onto the board, one task each (just triage -s xdr -s purview)
triage *args:
    @if [ -z "{{ plan_id }}" ]; then echo 'Set MC_PLAN_ID (env or .env); find it with: just plans "Your Team Name"'; exit 1; fi; uv run mc.py post --plan-id "{{ plan_id }}" --week last {{ args }}

# Same as triage, but show what would be created without writing anything
triage-dry *args:
    @if [ -z "{{ plan_id }}" ]; then echo 'Set MC_PLAN_ID (env or .env); find it with: just plans "Your Team Name"'; exit 1; fi; uv run mc.py post --plan-id "{{ plan_id }}" --week last --dry-run {{ args }}

# One rollup task summarising last month, e.g. just month-rollup -s azure
month-rollup *args:
    @if [ -z "{{ plan_id }}" ]; then echo 'Set MC_PLAN_ID (env or .env); find it with: just plans "Your Team Name"'; exit 1; fi; uv run mc.py post --plan-id "{{ plan_id }}" --month last --rollup {{ args }}

# Lint plus a help-render smoke of both engines (what CI runs)
check:
    uvx ruff check mc.py
    uv run mc.py --help > /dev/null
    for cmd in messages summarise post plans; do uv run mc.py "$cmd" --help > /dev/null; done
    pwsh -NoProfile -File ./mc.ps1 help > /dev/null
    @echo "All good."
