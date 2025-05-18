# zizmor-action

Run [`zizmor`] from GitHub Actions!

> [!WARNING]
> This action is not ready for public use!

## Table of Contents

- [Quickstart](#quickstart)
  - [Usage with Github Advanced Security (recommended)](#usage-with-github-advanced-security-recommended)
  - [Usage without Github Advanced Security](#usage-without-github-advanced-security)
- [Inputs](#inputs)
  - [`inputs`](#inputs)
  - [`online-audits`](#online-audits)
  - [`version`](#version)
  - [`token`](#token)
  - [`advanced-security`](#advanced-security)
- [Permissions](#permissions)

## Quickstart

This section lists a handful of quick-start examples to get you up and
running with `zizmor` and `zizmor-action`. See the [Inputs](#inputs)
section for more details on how `zizmor-action` can be configured.

### Usage with Github Advanced Security (recommended)

> [!IMPORTANT]
> This mode requires that your repository is public or that you have
> [Advanced Security] as a paid feature on your private repository.
>
> If neither of these applies to you, you can use `zizmor-action`
> with `advanced-security: false`; see below for more details.

> [!IMPORTANT]
> In this mode, the action will **not** fail when `zizmor` produces findings.
> This is because Advanced Security encourages workflows to only fail
> on internal errors.
>
> To use workflow failure as a blocking signal, you can use GitHub's rulesets
> feature. For more information, see
> [About code scanning alerts - Pull request check failures for code scanning alerts].

> [!NOTE]
> This is the recommended way to use `zizmor-action` as it provides
> stateful analysis and enables incremental triage.

`zizmor-action` integrates with GitHub's [Advanced Security]
by default, giving you access to `zizmor`'s findings via your
repository's security tab.

```yaml
name: GitHub Actions Security Analysis with zizmor 🌈

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

permissions: {}

jobs:
  zizmor:
    runs-on: ubuntu-latest
    permissions:
      security-events: write
      contents: read # only needed for private repos
      actions: read # only needed for private repos
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Run zizmor 🌈
        uses: zizmorcore/zizmor-action@v0.0.2
```

### Usage without Github Advanced Security

If you can't or don't want to use GitHub's [Advanced Security] functionality,
you can still use `zizmor-action` without any issues or feature limitations!

To do so, you can set `advanced-security: false`
and omit the `security-events: write` permission. For example:

```yaml
name: GitHub Actions Security Analysis with zizmor 🌈

on:
  push:
    branches: ["main"]
  pull_request:
    branches: ["**"]

permissions: {}

jobs:
  zizmor:
    runs-on: ubuntu-latest
    permissions:
      contents: read # only needed for private repos
      actions: read # only needed for private repos
    steps:
      - name: Checkout repository
        uses: actions/checkout@v4
        with:
          persist-credentials: false

      - name: Run zizmor 🌈
        uses: zizmorcore/zizmor-action@v0.0.2
        with:
          advanced-security: false
```

## Inputs

### `inputs`

*Default*: `.`

`inputs` is a whitespace-separated list of inputs to pass to `zizmor`.
It defaults to `.` (the current working directory).

This set of inputs can be anything `zizmor` would normally accept as an
input. For example, you can audit one or more files, directories, or remote
repositories:

```yaml
- name: Run zizmor 🌈
  uses: zizmorcore/zizmor-action@v0.0.2
  with:
    inputs: |
      .github/workflows/fishy.yml
      my-actions/
      other-org/other-repo@main
```

See `zizmor`'s [Input collection] documentation for more information.

### `online-audits`

*Default*: `true`

`online-audits` controls whether `zizmor` runs online audits. Running without
`online-audits` is faster but will produce fewer results.

See `zizmor`'s [Audit Rules] documentation for more information on which
audits are online-only.

### `version`

*Default*: `latest`

`version` is the version of `zizmor` to use. It must be provided as
either an exact version (e.g. `v1.7.0`) or the special value `latest`,
which will always use the latest version of `zizmor`.

### `token`

*Default*: `${{ github.token }}`

`token` is the GitHub token to use for accessing the GitHub REST API
during online audits, as well as for uploading results to Advanced Security
when [`advanced-security`](#advanced-security) is enabled.

### `advanced-security`

*Default*: `true`

`advanced-security` controls whether `zizmor-action` uses GitHub's
[Advanced Security] functionality. If set to `false`, `zizmor-action`
will not upload results to Advanced Security, and will instead
print them to the console.

## Permissions

[`zizmor`]: https://docs.zizmor.sh
[Advanced Security]: https://docs.github.com/en/get-started/learning-about-github/about-github-advanced-security
[About code scanning alerts - Pull request check failures for code scanning alerts]: https://docs.github.com/en/code-security/code-scanning/managing-code-scanning-alerts/about-code-scanning-alerts#pull-request-check-failures-for-code-scanning-alerts
[Input collection]: https://docs.zizmor.sh/usage/#input-collection
[Audit Rules]: https://docs.zizmor.sh/audits/
