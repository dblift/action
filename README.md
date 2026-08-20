# DBLift

Run [dblift](https://dblift.com) database migrations in your CI pipeline.

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
          command: check
          extras: postgresql
```

`command: check` runs `migrate`, then `validate`, then `info` against the
ephemeral Postgres service above.

## Inputs

| Name                | Description                                                                                                    | Default      |
| -------------------- | --------------------------------------------------------------------------------------------------------------- | ------------- |
| `command`            | Shortcut pipeline: `check`, `migrate`, `validate` or `info`. Ignored when `args` is set.                        | `check`       |
| `args`               | Raw arguments passed to the dblift CLI. Overrides `command`.                                                    | *(empty)*     |
| `packages`           | Full pip requirement specifiers to install, space-separated. Overrides `version` and `extras`.                  | *(empty)*     |
| `version`            | Version of the dblift package to install. Empty installs the latest release.                                   | *(empty)*     |
| `extras`             | Database driver extra to install. Valid values: `postgresql`, `mysql`, `mariadb`, `oracle`, `sqlserver`, `db2`, `duckdb`, `cosmosdb`, `mongodb`, `redshift`, `snowflake`, `neon`, `supabase`, `aurora-postgresql`, `alloydb`, `yugabytedb`, `timescaledb`, `citus`, `cockroachdb`, `all`. | `postgresql`  |
| `python-version`     | Python version used to run dblift.                                                                              | `3.11`        |
| `working-directory`  | Directory containing the dblift configuration file.                                                             | `.`           |
| `env-name`           | Environment to select, passed as `--env <name>`.                                                                | *(empty)*     |
| `index-url`          | Alternative pip index URL.                                                                                      | *(empty)*     |
| `summary`            | Write the result to the GitHub step summary.                                                                    | `true`        |
| `pr-comment`         | Post the migration plan as a pull request comment.                                                              | `false`       |

## Outputs

| Name             | Description                                        |
| ----------------- | ----------------------------------------------------- |
| `exit-code`       | Exit status returned by the dblift CLI.               |
| `pending-count`   | Number of migrations not yet applied.                 |
| `sql`             | SQL that a dry run reported it would execute.         |

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
          command: check
          pr-comment: true
```

This requires `permissions: pull-requests: write` on the workflow or job, as
above. On pull requests from forks, the token GitHub provides is read-only,
so the Action cannot post a comment there; it falls back to writing the plan
to the job's step summary instead. Posting the comment also runs with
`continue-on-error`, so a failure to comment never fails the job.

### Passing raw arguments

```yaml
- uses: dblift/action@v1
  with:
    args: 'baseline --version 3'
```

`args` is a raw passthrough to the dblift CLI and overrides `command`.

## How it works

This Action installs the `dblift` Python package into your runner with pip
and runs the dblift command you request against the database you configure.
It reports the result through the job's exit status and outputs, and
optionally the step summary or a pull request comment. It does not start or
manage a database — you supply one — and nothing it does leaves your runner.

## Learn more

[dblift.com](https://dblift.com)
