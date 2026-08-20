# Changelog

All notable changes to this project are documented in this file.

The format is based on Keep a Changelog, and this project adheres to
Semantic Versioning.

## [Unreleased]

### Added

- Composite GitHub Action that installs the `dblift` Python package and runs
  a migration command against a database you configure. `command` selects a
  shortcut pipeline (`check`, `migrate`, `validate`, `info`); `args` passes
  raw dblift CLI arguments instead.
- `packages`, `version`, `extras` and `index-url` inputs to control how the
  `dblift` package is installed.
- `working-directory` and `env-name` inputs to select the project and
  environment dblift runs against.
- `exit-code` and `pending-count` outputs, and an optional GitHub step
  summary (`summary` input) reporting the command run, its exit status and
  its output.
- `pr-comment` input to render a dry-run migration plan and post it as a
  sticky pull request comment, updated in place on each push; falls back to
  the step summary when the token cannot post (e.g. pull requests from
  forks) and never fails the job on its own.
