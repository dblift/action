# DBLift

Run dblift database migrations in your CI pipeline.

## Quick start

```yaml
name: Database migrations
on: pull_request

jobs:
  migrate:
    runs-on: ubuntu-latest
    env:
      DBLIFT_DB_URL: postgresql+psycopg://dblift:dblift@localhost:5432/dblift
    services:
      postgres:
        image: postgres:16
        env:
          POSTGRES_USER: dblift
          POSTGRES_PASSWORD: dblift
          POSTGRES_DB: dblift
        ports:
          - 5432:5432
        options: >-
          --health-cmd "pg_isready -U dblift -d dblift"
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - uses: actions/checkout@v5
      - uses: dblift/action@v1
        with:
          command: migrate
          extras: postgresql
```

Applying the migrations to the ephemeral Postgres service above *is* the
check: dblift's `migrate` validates before it applies, so a bad checksum or a
broken ordering fails the job rather than being written to the database.

## Inputs

| Name                | Description                                                                                                    | Default      |
| -------------------- | --------------------------------------------------------------------------------------------------------------- | ------------- |
| `command`            | dblift command to run: `migrate`, `validate` or `info`. Ignored when `args` is set. | *(none — set this or `args`)* |
| `args`               | Raw arguments passed to the dblift CLI, split like a shell command line (quotes supported). Overrides `command`. When set, no migration plan is rendered for `pr-comment` and `pending-count` is left empty. | *(empty)*     |
| `packages`           | Full pip requirement specifiers to install, space-separated. Overrides `version` and `extras`.                  | *(empty)*     |
| `version`            | Version of the dblift package to install. Empty installs the latest release.                                   | *(empty)*     |
| `extras`             | Database driver extra to install. Valid values: `postgresql`, `mysql`, `mariadb`, `oracle`, `sqlserver`, `db2`, `duckdb`, `cosmosdb`, `mongodb`, `redshift`, `snowflake`, `neon`, `supabase`, `aurora-postgresql`, `alloydb`, `yugabytedb`, `timescaledb`, `citus`, `cockroachdb`, `all`. | `postgresql`  |
| `python-version`     | Python version used to run dblift.                                                                              | `3.11`        |
| `working-directory`  | Directory containing the dblift configuration file.                                                             | `.`           |
| `env-name`           | Environment to select, passed as `--env <name>`.                                                                | *(empty)*     |
| `config`             | Path to the dblift configuration file, relative to `working-directory`, passed as `--config <path>`. Empty uses default discovery. | *(empty)*     |
| `scripts`            | Path to the migrations directory, relative to `working-directory`, passed as `--scripts <path>`. Empty uses default discovery. | *(empty)*     |
| `index-url`          | Alternative pip index URL.                                                                                      | *(empty)*     |
| `summary`            | Write the result to the GitHub step summary.                                                                    | `true`        |
| `pr-comment`         | Post the migration plan as a pull request comment.                                                              | `false`       |

## Outputs

| Name             | Description                                        |
| ----------------- | ----------------------------------------------------- |
| `exit-code`       | Exit status returned by the dblift CLI, or the script's own status when dblift never ran. |
| `pending-count`   | Number of migrations not yet applied. Empty when `args` is set or the probe fails; both cases are logged. |
| `sql`             | SQL that a dry run reported it would execute. Populated when `pr-comment` is enabled and `args` is empty. |

Reading `exit-code` requires `continue-on-error: true` on the step that calls
this Action. The Action exits with dblift's exit status, so without it a
non-zero result fails the job immediately and no later step runs to read the
output.

## Examples

### Validate only, on pull requests touching migrations

```yaml
on:
  pull_request:
    paths:
      - 'migrations/**'

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: dblift/action@v1
        with:
          command: validate
```

### Post the migration plan as a pull request comment

```yaml
on: pull_request

permissions:
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: dblift/action@v1
        with:
          command: migrate
          pr-comment: true
```

This requires `permissions: pull-requests: write` on the workflow or job, as
above. On pull requests from forks, the token GitHub provides is read-only,
so the Action cannot post a comment there; it falls back to writing the plan
to the job's step summary instead. Rendering and posting the plan absorbs its
own failures, so it never fails the job.

The plan is rendered before the command runs, so it reports the migrations
that are pending at the start of the job — including for `command: migrate`,
which goes on to apply them.

### Non-default config and migrations directory

```yaml
on: pull_request

permissions:
  pull-requests: write

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - uses: dblift/action@v1
        with:
          command: migrate
          config: dblift.ci.yaml
          scripts: db/migrations
          pr-comment: true
```

`config` and `scripts` are relative to `working-directory`. Leave either
empty to keep dblift's default discovery. The same flags are passed to the
real command, the dry-run plan, and the `pending-count` probe, so
`pr-comment` and `pending-count` still work. `args` still overrides
`command` and still skips both.

### Passing raw arguments

```yaml
- uses: dblift/action@v1
  with:
    args: 'baseline --baseline-version 3'
```

`args` is a raw passthrough to the dblift CLI and overrides `command`. It is
split like a shell command line, so quoted values containing spaces survive
intact.

## How it works

This Action installs the `dblift` Python package into your runner with pip
and runs the dblift command you request against the database you configure.
It reports the result through the job's exit status and outputs, and
optionally the step summary or a pull request comment. It does not start or
manage a database — you supply one — and nothing it does leaves your runner.

## Learn more

[dblift.com](https://dblift.com)
