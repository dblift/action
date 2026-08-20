# Implementation plan — dblift composite GitHub Action (MVP)

## Context

This repository provides the official GitHub Action for [dblift](https://github.com/dblift/dblift),
a Python database migration toolkit distributed on PyPI as `dblift`.

The Action is a **composite action**: it installs the `dblift` package with
`actions/setup-python` + pip, runs a dblift command in the caller's workflow,
and reports the result. It does not start a database — the caller supplies one
(typically a `services:` container) and points dblift at it through
`DBLIFT_DB_URL` or a `dblift.yaml` file.

Marketplace requires `action.yml` at the repository root, so this repository is
public and everything in it is public. Keep it a thin wrapper: install, run,
report. No product logic belongs here.

### Environment for local verification

- `jq` is available.
- **Docker is NOT available. Apple `container` (CLI 1.0.0) is**, and runs real
  PostgreSQL and MySQL images locally. It differs from Docker in one way that
  matters: **containers get their own IP on a private network and there is no
  port publishing to `localhost`.** Read the address from `container ls` and
  point dblift at it, for example
  `DBLIFT_DB_URL=postgresql+psycopg://dblift:dblift@192.168.64.28:5432/dblift`.
  Verified working end to end against `postgres:16`.
- **The `tests/` suite stays on SQLite regardless.** It must run unchanged on
  GitHub's `ubuntu-latest` runners, where Apple `container` does not exist and
  the equivalent is a `services:` block. SQLite needs no driver extra, no
  network and no daemon, so the suite stays hermetic and portable. Apple
  `container` is for **manually validating the PostgreSQL recipes this
  repository publishes** — the README quick start and the smoke job — before
  they are trusted. Making `tests/` depend on a container runtime is a
  regression, not an improvement.
- Other containers are already running on this machine from unrelated work.
  Create only your own, name them with a `dblift-action-` prefix, and remove
  the ones you create when you are done.
- `shellcheck`, `actionlint` and `yq` are NOT installed. Validate YAML with
  Python (`python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" FILE`).
- `dblift` is already installed on this machine. **Always export
  `DBLIFT_DISABLE_CLI_EXTENSIONS=1`** before invoking it locally: this machine
  carries stale extension metadata and the CLI aborts at import without it.
  That variable is a local workaround only — it must never appear in the
  Action's own code, workflows or docs.

## Global Constraints

1. **Thin wrapper.** The Action installs a package and runs a command. No
   migration logic, no SQL parsing, no product behaviour is reimplemented here.
2. **Never parse human-readable text output.** Machine-readable output only:
   - `dblift info --format json` → JSON on **stdout**.
   - Everything else → `dblift --log-format json --log-dir DIR --log-file NAME`
     writes a JSON log **file**.
   Banners, status lines and the `SQL Statements:` block go to **stderr** and
   are never a parsing target. Scraping stderr is a defect, not a shortcut.
3. **Always surface stderr.** dblift writes its diagnostics there. A run that
   hides stderr turns a clear error message into a silent failure. Job logs and
   the step summary must both carry it.
4. **Never write into the caller's workspace.** Log files and temporary output
   go to `$RUNNER_TEMP`.
5. **Fail loudly.** The Action's exit status is the dblift exit status. Never
   swallow a non-zero exit. dblift exit codes: `0` success, `1` command failure,
   `2` usage error, `4` command unavailable in this installation, `130`
   interrupted.
6. **Public-repository hygiene.** This repository documents the open-source
   command surface only: `migrate`, `validate`, `info`, `undo`, `baseline`,
   `repair`, `clean`, `import-flyway`. Other commands are reachable through the
   generic `args` input, which is deliberately open-ended — do not enumerate,
   name or document them, and do not name any licensing or configuration
   variable associated with them. A single link to https://dblift.com is the
   only pointer allowed.
7. **POSIX shell, `set -euo pipefail`.** Scripts run under `bash`. Quote every
   expansion. No bashisms beyond bash 3.2 (macOS runners ship it).
8. **Every script gets a local test** under `tests/`, runnable with no network
   and no Docker, driven by a plain `tests/run.sh`.

## Task 1: Repository scaffold and `action.yml` interface

Create the repository skeleton and the complete Action interface. No behaviour
yet — this task defines the contract that later tasks implement.

### Files

- `action.yml` (repository root — required by Marketplace)
- `LICENSE` — Apache License 2.0, copyright holder `DBLift`
- `.gitignore` — ignore `__pycache__/`, `*.pyc`, `.venv/`, `tests/tmp/`
- `README.md` — placeholder heading only; Task 7 writes the real content

### `action.yml` metadata

```yaml
name: 'DBLift'
description: 'Run database migrations and validate migration state in CI'
author: 'DBLift'
branding:
  icon: 'database'
  color: 'blue'
runs:
  using: 'composite'
```

### Inputs — exact names, defaults and descriptions

| Input | Required | Default | Description |
|---|---|---|---|
| `command` | no | `check` | Shortcut pipeline: `check`, `migrate`, `validate` or `info`. Ignored when `args` is set. |
| `args` | no | `""` | Raw arguments passed to the dblift CLI. Overrides `command`. |
| `packages` | no | `""` | Full pip requirement specifiers to install, space-separated. Overrides `version` and `extras`. |
| `version` | no | `""` | Version of the dblift package to install. Empty installs the latest release. |
| `extras` | no | `postgresql` | Database driver extra to install. |
| `python-version` | no | `3.11` | Python version used to run dblift. |
| `working-directory` | no | `.` | Directory containing the dblift configuration file. |
| `env-name` | no | `""` | Environment to select, passed as `--env <name>`. |
| `index-url` | no | `""` | Alternative pip index URL. |
| `summary` | no | `true` | Write the result to the GitHub step summary. |
| `pr-comment` | no | `false` | Post the migration plan as a pull request comment. |

Valid `extras` values, for the description text: `postgresql`, `mysql`,
`mariadb`, `oracle`, `sqlserver`, `db2`, `duckdb`, `cosmosdb`, `mongodb`,
`redshift`, `snowflake`, `neon`, `supabase`, `aurora-postgresql`, `alloydb`,
`yugabytedb`, `timescaledb`, `citus`, `cockroachdb`, `all`.

### Outputs — exact names

| Output | Description |
|---|---|
| `exit-code` | Exit status returned by the dblift CLI. |
| `pending-count` | Number of migrations not yet applied. |
| `sql` | SQL that a dry run reported it would execute. |

Declare outputs with `value: ${{ steps.<step-id>.outputs.<name> }}`. Use the
step id `dblift` for the step that will run the CLI; Task 5 adds that step.

### Verification

- `python3 -c "import yaml,sys; yaml.safe_load(open('action.yml'))"` succeeds.
- A check confirms every input and output above is present with exactly the
  documented default; assert on the parsed YAML, not on a text grep.
- `LICENSE` is the full unmodified Apache 2.0 text.

## Task 2: `scripts/run.sh` — install, execute, report

Implement the Action's core: install the package, run the requested command,
capture the result, expose the outputs.

### Interface

`scripts/run.sh` takes no positional arguments and reads this environment:

`INPUT_COMMAND`, `INPUT_ARGS`, `INPUT_PACKAGES`, `INPUT_VERSION`,
`INPUT_EXTRAS`, `INPUT_WORKING_DIRECTORY`, `INPUT_ENV_NAME`, `INPUT_INDEX_URL`,
`INPUT_SUMMARY`, plus the runner-provided `GITHUB_OUTPUT`, `GITHUB_STEP_SUMMARY`
and `RUNNER_TEMP`.

It must also honour `DBLIFT_BIN` (default `dblift`) so the tests can point it at
a wrapper script. Do not add any other test-only hook.

### Behaviour

1. **Resolve the install specifier**, in this precedence order:
   - `INPUT_PACKAGES` non-empty → use it verbatim (word-split on spaces).
   - else `dblift[<INPUT_EXTRAS>]` , with `==<INPUT_VERSION>` appended when
     `INPUT_VERSION` is non-empty.
   Emit `pip install` with `--index-url "<INPUT_INDEX_URL>"` when that input is
   non-empty. Print the resolved specifier before installing.
2. **Change to `INPUT_WORKING_DIRECTORY`** before running anything.
3. **Build the command line**:
   - `INPUT_ARGS` non-empty → run `dblift <args>` verbatim, and nothing else.
   - else dispatch on `INPUT_COMMAND`:
     - `migrate` → `dblift migrate`
     - `validate` → `dblift validate`
     - `info` → `dblift info`
     - `check` → `dblift migrate`, then `dblift validate`, then `dblift info`,
       in that order, stopping at the first non-zero exit.
     - anything else → fail with a message naming the valid values.
   - When `INPUT_ENV_NAME` is non-empty, append `--env "<INPUT_ENV_NAME>"` to
     every dblift invocation.
4. **Stream both streams to the job log** while capturing them, so a failure is
   visible in the log as it happens. stderr must reach the log verbatim
   (Global Constraint 3).
5. **Compute `pending-count`** by running
   `dblift info --format json` (plus `--env` when set) and counting entries
   where `.status == "PENDING"`:
   ```
   jq '[.migrations[] | select(.status == "PENDING")] | length'
   ```
   If that command fails or returns no parseable JSON, set `pending-count` to
   the empty string rather than failing the run — it is a report, not a gate.
6. **Write outputs** `exit-code` and `pending-count` to `$GITHUB_OUTPUT` using
   the `name=value` form. Use a heredoc delimiter for any value that may
   contain newlines.
7. **Write the step summary** when `INPUT_SUMMARY` is `true`: the command that
   ran, the exit status, the pending count, and the captured stderr inside a
   fenced block. Skip silently when `GITHUB_STEP_SUMMARY` is unset.
8. **Exit with the dblift exit status.**

### Verification

`tests/test-run.sh`, driven from `tests/run.sh`, using SQLite and a fake
`GITHUB_OUTPUT`/`GITHUB_STEP_SUMMARY`/`RUNNER_TEMP` under `tests/tmp/`. Set
`DBLIFT_BIN` to a wrapper that exports `DBLIFT_DISABLE_CLI_EXTENSIONS=1` and
execs the real binary; skip installation in tests by setting
`INPUT_PACKAGES=""` and short-circuiting the install step with the documented
`DBLIFT_SKIP_INSTALL=1` variable (add that variable, and document it in the
script's header comment as test-only).

Cases that must pass:

1. **Clean history** — two SQL migrations, `command=check` → exit 0, and
   `pending-count` written as `0` after the migrations are applied.
2. **Pending migrations** — fresh database, `command=info` → exit 0 and
   `pending-count` equal to `2`.
3. **Modified migration** — apply migrations, append a comment line to an
   already-applied migration file, then `command=validate` → **exit 1**. This is
   the case that proves the Action can fail; without it the Action is useless.
4. **Unknown command** — `command=bogus` → non-zero exit and a message listing
   the valid values.
5. **`args` overrides `command`** — `args="info --format json"` with
   `command=migrate` → the JSON reaches stdout and no migration is applied.

Fixture migrations, used by every case:

```sql
-- migrations/V1__create_users.sql
CREATE TABLE users (id INTEGER PRIMARY KEY, email TEXT NOT NULL);
```
```sql
-- migrations/V2__add_index.sql
CREATE INDEX idx_users_email ON users(email);
ALTER TABLE users ADD COLUMN name TEXT;
```

Fixture config:

```yaml
database:
  type: sqlite
  url: "sqlite:///test.db"
migrations:
  directories: [migrations]
```

## Task 3: `scripts/plan-sql.sh` — read the dry-run plan from the JSON log

Produce the Markdown rendering of a migration plan, read from dblift's JSON log.

### Interface

`scripts/plan-sql.sh <json-log-path>` writes Markdown to stdout.

### Producing the log (for the caller and the tests)

```
dblift --log-format json --log-dir "$RUNNER_TEMP" --log-file plan.json \
       migrate --dry-run --show-sql
```

The file contains, at the top level:

```json
{
  "log_format_version": "1.0",
  "dblift_version": "3.9.0",
  "status": "SUCCESS",
  "show_sql": true,
  "sql": [
    {
      "script": "V2__add_index.sql",
      "version": "2",
      "description": "add_index",
      "statements": [
        "CREATE INDEX idx_users_email ON users(email);",
        "ALTER TABLE users ADD COLUMN name TEXT;"
      ]
    }
  ]
}
```

Read the **top-level `.sql`** key. The same payload is repeated under
`.commands[].sql`; ignore that copy.

### Rendering

For each entry in `.sql`, emit a section:

```markdown
### V2 — add_index

```sql
CREATE INDEX idx_users_email ON users(email);
ALTER TABLE users ADD COLUMN name TEXT;
```
```

Use `version` and `description` for the heading; fall back to `script` when
`description` is empty or absent. When `.sql` is absent or empty, emit exactly:

```markdown
_No pending migrations — nothing to apply._
```

### Verification

`tests/test-plan-sql.sh`:

1. **Fixture rendering** — a checked-in `tests/fixtures/plan.json` holding the
   payload above renders to the expected Markdown, compared with `diff`.
2. **Empty plan** — a fixture with `"sql": []` renders the no-migrations
   sentence.
3. **Missing key** — a fixture with no `sql` key renders the same sentence and
   exits 0.
4. **End-to-end** — run the real dblift command above against the SQLite
   fixture project, then render the produced log; assert the output contains
   both migration headings and the `CREATE TABLE` statement. This proves the
   documented flags actually produce the documented file.
5. **SQL fence integrity** — assert the rendered output has an even number of
   ```` ``` ```` fence markers.


## Task 4: `scripts/comment.sh` — sticky pull request comment

Post the rendered migration plan as a single pull request comment that is
updated on every push, rather than a new comment each time.

### Interface

`scripts/comment.sh <markdown-file>` reads the Markdown body from the given
file and posts or updates the comment.

Environment: `GITHUB_REPOSITORY`, `GITHUB_EVENT_PATH`, `GITHUB_STEP_SUMMARY`,
`GITHUB_TOKEN`. Honour `GH_BIN` (default `gh`) so the tests can substitute a
recorder; do not add any other test-only hook.

### Behaviour

1. **Resolve the pull request number** from the event payload at
   `$GITHUB_EVENT_PATH`: `jq -r '.pull_request.number // empty'`. When the file
   is missing, unreadable, or yields no number, this is not a pull request run
   — write the body to `$GITHUB_STEP_SUMMARY` and **exit 0**.
2. **Marker.** Prepend the hidden marker `<!-- dblift-action -->` as the first
   line of every body written. It identifies the comment to update and is
   invisible in rendered Markdown.
3. **Find the existing comment**:
   ```
   gh api "repos/$GITHUB_REPOSITORY/issues/$PR/comments" --paginate \
     --jq 'map(select(.body | contains("<!-- dblift-action -->"))) | .[0].id // empty'
   ```
4. **Update or create**: with an id, `PATCH repos/<repo>/issues/comments/<id>`;
   without one, `POST repos/<repo>/issues/<pr>/comments`. Pass the body with
   `--field body=@<file>` or an equivalent that does not expand shell
   metacharacters in the SQL. Never interpolate the body into the command line.
5. **Truncate** bodies exceeding **65000** bytes (the API limit is 65536; the
   margin absorbs the marker and the notice). Cut at a line boundary, close any
   unterminated fence, then append:
   ```

   _Output truncated. See the job logs for the full migration plan._
   ```
   The result must always have a balanced number of ```` ``` ```` markers.
6. **Never fail the job.** Any `gh` failure — a read-only token on a fork pull
   request is the common case — is reported on stderr, written to the step
   summary instead, and the script exits 0. Posting a comment is a convenience;
   it must not turn a passing migration check red.

### Verification

`tests/test-comment.sh` uses a mock `gh` at `tests/mocks/gh` that appends every
invocation to `$GH_LOG` and prints canned responses driven by `$GH_MODE`
(`empty`, `existing`, `fail`). Cases:

1. **No existing comment** (`GH_MODE=empty`) — exactly one `POST` to
   `issues/<pr>/comments`, and no `PATCH`.
2. **Existing comment** (`GH_MODE=existing`, id `4242`) — exactly one `PATCH` to
   `issues/comments/4242`, and no `POST`.
3. **Marker present** — the body written in both cases starts with
   `<!-- dblift-action -->`.
4. **Oversized body** — a generated body well over 65000 bytes is truncated, the
   notice is present, and the fence count is even.
5. **`gh` failure** (`GH_MODE=fail`) — script exits **0**, the step summary file
   contains the body, and stderr explains the failure.
6. **Not a pull request** — `GITHUB_EVENT_PATH` pointing at `{}` → exit 0, the
   step summary contains the body, and `$GH_LOG` is empty.

## Task 5: Wire the scripts into `action.yml`

Turn the interface from Task 1 into a working composite action using the
scripts from Tasks 2, 3 and 4.

### Steps, in order

1. `actions/setup-python@v5` with `python-version: ${{ inputs.python-version }}`
   and `cache: pip`.
2. A `run` step with `id: dblift` and `shell: bash` invoking
   `"$GITHUB_ACTION_PATH/scripts/run.sh"`, passing every input through the
   `INPUT_*` environment variables named in Task 2.
3. A `run` step with `shell: bash`, conditional on
   `inputs.pr-comment == 'true'`, which:
   - runs `dblift --log-format json --log-dir "$RUNNER_TEMP" --log-file plan.json migrate --dry-run --show-sql`
     (adding `--env` when `env-name` is set),
   - renders it with `scripts/plan-sql.sh` into `$RUNNER_TEMP/plan.md`,
   - sets the `sql` output from that file using a heredoc delimiter,
   - posts it with `scripts/comment.sh "$RUNNER_TEMP/plan.md"`.
   This step must not fail the job: the plan is informational.

Use `$GITHUB_ACTION_PATH` for every script reference — the action's files are
not in the caller's workspace. Mark scripts executable in git
(`git update-index --chmod=+x`) so they run when checked out.

### Verification

- `action.yml` parses, and a check asserts: every `run` step declares
  `shell: bash`, every script reference is under `$GITHUB_ACTION_PATH`, and the
  step id the outputs reference exists.
- `git ls-files -s scripts/` shows mode `100755` for every script.

## Task 6: CI workflows

### `.github/workflows/test.yml`

Runs the local test suite on every push and pull request:

- `runs-on: ubuntu-latest`
- checkout, `actions/setup-python@v5` with Python `3.11`
- `pip install "dblift"` (no extra needed — the suite uses SQLite)
- `bash tests/run.sh`

Add a second job, `action-smoke`, that consumes the action from the checked-out
repository (`uses: ./`) against the SQLite fixture project, asserting the job
succeeds and that the `pending-count` output is exactly `0` after
`command: check` has applied the migrations. Copy `tests/fixtures/project` to a
temporary directory first so the action runs outside the repository root.
Install bare `dblift` via `packages:` — SQLite needs no driver extra, and this
is the only coverage of the `packages` input.

Add a third job, `action-smoke-postgres`, with a `services:` PostgreSQL
container, consuming the action the same way but with `extras: postgresql`
against a PostgreSQL fixture project. This job exists because Task 7 publishes a
PostgreSQL quick start in the README, and **a recipe this repository publishes
but never executes is exactly the failure this plan set out to avoid.** It is
also the only coverage of the default `extras` value.

Note that GitHub's `services:` publishes container ports to `localhost` on the
runner, unlike Apple `container` locally — so the connection URL here is
`postgresql+psycopg://dblift:dblift@localhost:5432/dblift`, with a `ports:`
mapping and a `pg_isready` health check on the service.

### `.github/workflows/release.yml`

On `release: [published]`, re-point the floating major tag at the released
commit, so `uses: dblift/action@v1` keeps working:

- derive the major from the release tag (`v1.2.3` → `v1`)
- force-update that tag and push it
- `permissions: contents: write`
- gate the retag on `bash tests/run.sh` passing first

### `.github/dependabot.yml`

Weekly updates for the `github-actions` ecosystem, directory `/`.

### Verification

Every YAML file parses with `yaml.safe_load`. A check asserts `test.yml`
contains both jobs and that `release.yml` triggers on `release` with type
`published` and declares `contents: write`.

**Plus one manual validation, because a workflow that only parses is not a
workflow that works.** The `services:` PostgreSQL recipe in `test.yml` cannot be
executed by the test suite, so prove the command sequence it runs is correct by
running that sequence by hand against a real PostgreSQL, using Apple
`container` (see Environment above):

```bash
container run -d --name dblift-action-pg \
  -e POSTGRES_USER=dblift -e POSTGRES_PASSWORD=dblift -e POSTGRES_DB=dblift \
  postgres:16
container ls                       # read the container's IP
export DBLIFT_DB_URL="postgresql+psycopg://dblift:dblift@<IP>:5432/dblift"
```

Then run the exact `migrate` → `validate` → `info` sequence the workflow
triggers, against a fixture project using `type: postgresql`, and confirm it
succeeds. Record the outcome in your report. Remove the container afterwards
(`container rm -f dblift-action-pg`). Do not add this to `tests/run.sh` — the
suite stays SQLite-only and runtime-free.

## Task 7: README, docs guard, CHANGELOG

### `README.md`

Sections, in this order:

1. Title and one-sentence description.
2. **Quick start** — the minimal workflow, using a PostgreSQL `services:`
   container, mirroring the shape the dblift documentation already recommends:
   `migrate` against the ephemeral CI database, then `validate`, then `info`.
   That is what `command: check` does, so the example uses `command: check`.
3. **Inputs** — the table from Task 1.
4. **Outputs** — the table from Task 1.
5. **Examples** — three: validate-only on pull requests touching
   `migrations/**`; the migration plan posted on pull requests with
   `pr-comment: true` (documenting the required
   `permissions: pull-requests: write` and that fork pull requests fall back to
   the step summary); and passing raw arguments with `args`.
6. **How it works** — three sentences: it installs the package, runs the
   command in your runner, and reports the result. State plainly that the
   database is supplied by the caller and that nothing leaves the runner.
7. A single link to https://dblift.com.

Respect Global Constraint 6 throughout.

### `scripts/check-docs.sh`

Guards Global Constraint 6 mechanically. Fails when any tracked `*.md` file or
`action.yml` contains a case-insensitive match for a configured list of tokens
that must not appear in this repository. Seed the list with the licensing and
configuration identifiers that belong to installations this Action does not
document: `--license-key`, `DBLIFT_LICENSE_KEY`, `license_info`. Keep the list
in one place at the top of the script, with a comment explaining that this
repository documents the open-source surface only. Exclude
`scripts/check-docs.sh` itself from the scan — it necessarily contains the
tokens it forbids.

Wire it into `tests/run.sh` and therefore into CI.

### `CHANGELOG.md`

Keep-a-Changelog format, one `## [Unreleased]` section describing the initial
release contents.

### Verification

- `bash scripts/check-docs.sh` exits 0 on the repository as written.
- A negative check: appending a forbidden token to a scratch Markdown file
  under the repository makes it exit non-zero. Remove the scratch file
  afterwards.
- `bash tests/run.sh` runs the docs guard along with everything else.
