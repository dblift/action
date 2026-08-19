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
- **Docker is NOT available**, so PostgreSQL/MySQL cannot be exercised locally.
  Use **SQLite** for every local end-to-end check — dblift supports it with no
  driver extra (`sqlite:///test.db`).
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
- `README.md` — placeholder heading only; Task 6 writes the real content

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
step id `dblift` for the step that will run the CLI; Task 4 adds that step.

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

## Task 4: Wire the scripts into `action.yml`

Turn the interface from Task 1 into a working composite action using the
scripts from Tasks 2 and 3.

### Steps, in order

1. `actions/setup-python@v5` with `python-version: ${{ inputs.python-version }}`
   and `cache: pip`.
2. A `run` step with `id: dblift` and `shell: bash` invoking
   `"$GITHUB_ACTION_PATH/scripts/run.sh"`, passing every input through the
   `INPUT_*` environment variables named in Task 2.
3. A `run` step, conditional on `inputs.pr-comment == 'true'`, that produces the
   JSON log and renders it with `scripts/plan-sql.sh`. Task 5's workflow does
   not exercise this; posting to the API is out of scope for this MVP — this
   step writes the rendered Markdown to `$GITHUB_STEP_SUMMARY` and to the `sql`
   output instead. Note that limitation in the input description.

Use `$GITHUB_ACTION_PATH` for every script reference — the action's files are
not in the caller's workspace. Mark scripts executable in git
(`git update-index --chmod=+x`) so they run when checked out.

### Verification

- `action.yml` still parses, and a check asserts: every step has `shell: bash`
  where it uses `run`, no step references a path outside `$GITHUB_ACTION_PATH`,
  and the `dblift` step id matches the one the outputs reference.
- `git ls-files -s scripts/` shows mode `100755` for every script.

## Task 5: CI workflows

### `.github/workflows/test.yml`

Runs the local test suite on every push and pull request:

- `runs-on: ubuntu-latest`
- checkout, `actions/setup-python@v5` with Python `3.11`
- `pip install "dblift"` (no extra needed — the suite uses SQLite)
- `bash tests/run.sh`

Add a second job, `action-smoke`, that consumes the action from the checked-out
repository (`uses: ./`) against the SQLite fixture project, asserting the job
succeeds and that the `pending-count` output is populated. Use a step that
copies `tests/fixtures/project` to a temporary directory first so the action
runs outside the repository root.

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

## Task 6: README, docs guard, CHANGELOG

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
   `migrations/**`; selecting an environment with `env-name`; passing raw
   arguments with `args`.
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
repository documents the open-source surface only.

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
