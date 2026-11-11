# dq_framework

A dbt package with the data quality framework of this project: the generic
tests that guard a model, and the collector that keeps their failures in the
database.

It knows nothing about the models it guards: every rule is declared in the
YAML of the model it belongs to, and the results are written to tables that the
project can read.

## Install it in a project

1. Put this folder where the project can reach it and declare it in
   `packages.yml` of the project:

   ```yaml
   packages:
     - local: dq_framework
   ```

   A folder that is published in a git repository works the same way:

   ```yaml
   packages:
     - git: "https://github.com/<org>/<repo>.git"
       revision: v1.0.0
   ```

2. Install it:

   ```bash
   dbt deps
   ```

3. Wire the collector. The results of the rules are collected by a hook, so the
   project needs one `on-run-end` hook in its `dbt_project.yml`:

   ```yaml
   on-run-end:
   - "{{ store_all_failures() }}"
   ```

   The macro can be called straight from the package
   (`{{ dq_framework.store_all_failures() }}`); the project of this repository
   wraps it in `macros/dq_hooks.sql`, so that the hook of `dbt_project.yml` does
   not depend on the name of the package.

   The rules of the package keep their failures on their own: the config call
   of `dq_config` turns `store_failures` on for every rule, so the project does
   not have to set it.

4. The audit schema must exist and the role must be allowed to write in it:

   ```sql
   create schema if not exists <DATABASE>.DBT_TEST__AUDIT
     authorization '<ROLE>';
   ```

## Declare a rule

A rule is a generic test of the package, called from the `data_tests:` block of
the model (or of one of its columns). The name of the package comes first:

```yaml
models:
  - name: gld_executive_daily
    data_tests:
      - dq_framework.should_be_unique:
          arguments:
            column_name: [AREA, KEY, DATE_REPORTED]
      - dq_framework.should_match_model:
          arguments:
            other_model: slv_executive_daily
            key_columns: [AREA, KEY, DATE_REPORTED]
            compare_columns: [PLAN, ACTUAL, MTD_ACTUAL, MTD_FORECAST]
            other_where: "IS_CURRENT"
            threshold_pct: 95
          config:
            severity: warn
```

A test passes when it returns no rows, so each test returns the rows that break
the rule.

## The vocabulary

| Test | Rule |
|---|---|
| `should_not_be_null` / `should_be_null` | the column is never / always null |
| `should_not_be_empty` | the column is not blank |
| `should_be_unique` | the column (or columns) hold one row per key |
| `should_be_in` | the value is one of `values` |
| `should_be_between` / `should_be_greater_than` / `should_be_less_than` | the value is in range |
| `should_be_positive` / `should_be_non_negative` | the value is > 0 / >= 0 |
| `should_be_true` / `should_be_false` | the flag is always true / false |
| `should_be_satisfied` | any SQL condition over the columns of the model |
| `should_be_within_sla` | the row was produced within `max_delay_seconds` of its reference date |
| `should_match_model` | every row has a matching row in another model or source, with the same values |

Every test takes the same optional arguments: `filter` (a WHERE on the relation
under test) and `threshold_pct` (the rule only fails when the share of broken
rows is worse than that percentage; omit it for a strict rule).
`should_match_model` also takes `key_columns`, `compare_columns`, the `other_*`
variants for the other side, `other_where`, `latest_by` and `match_both_ways`.

A NULL value breaks every rule that looks at a value (`in`, `between`, `greater
than`, ...) and never breaks `should_not_be_null`. Pair the two when a column
must hold a value.

## Severity

`severity: error` fails the build, `severity: warn` only reports. The rules
that guard the business key are errors; the tolerance rules (accuracy,
consistency, validity, timeliness) are warnings at their `threshold_pct`, so a
breach is reported without stopping the pipeline.

Every rule of this package carries the `dq` tag, so the whole suite runs
read-only with `dbt test --select tag:dq`.

## What is written to the database

dbt writes the rows that break a rule to a table of its own, in the audit
schema, one table per rule, and the hook of the project collects them into
three tables (in the schema of the target):

| Table | Content |
|---|---|
| `DQ_FAILURES` | the rows that broke a rule in the last run, with the rule they broke |
| `DQ_FAILURES_HISTORY` | the same, for every run, with the `run_id` of the run |
| `DQ_RULE_STATS` | one row per rule per run: `evaluated_count`, `broken_count`, `passed_count`, `rule_score`, `rule_status` |

The rule is named the way it is declared: `rule_type::model::column`, for
example `should_be_in::gld_executive_monthly::AREA`. The failing row keeps the
context of the rule that broke it (the key count of a `should_be_unique`, both
sides of a `should_match_model`, the delay of a `should_be_within_sla`).

Only the rules that broke in the run are read from the audit schema, so the
leftovers of an older run never end up in the result.

## Adding a rule

A rule that does not exist yet goes in its own file in `macros/`, named after
the test, with three parts: the rows it looks at, the condition that breaks
them, and the test itself.

```sql
{% macro dq_source_should_be_even(relation, column_name, filter=none) -%}
{{ dq_framework.dq_source(relation, filter) }}
{%- endmacro %}

{% macro dq_violation_should_be_even(column_name) -%}
{{ column_name ~ ' is null or ' ~ column_name ~ ' % 2 <> 0' }}
{%- endmacro %}

{% test should_be_even(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_assert(dq_framework.dq_source_should_be_even(model, column_name, filter),
                            dq_framework.dq_violation_should_be_even(column_name), threshold_pct) }}
{% endtest %}
```

The test does not set its config: `dq_assert` calls `dq_config`, which gives
the rule the `dq` tag and keeps its failures in the database. A rule that does
not go through `dq_assert` has to call `dq_config` itself.

Then the rule is declared in the `data_tests:` of the model, and the collector
has to know how to count its rows: add a branch to `dq_rule_source_sql` and to
`dq_rule_violation_sql` in `macros/dq_rule_sql.sql`.

## Notes for anyone who works on the package

- **The calls are prefixed with the name of the package** (`dq_framework.dq_assert`).
  dbt only puts the macros of the macro path in scope, and a package does not
  put its own macros in scope by their bare name.
- **The rules live in `macros/`, not in `tests/generic/`.** dbt registers the
  macros of a file as package macros only when the file is in the macro path;
  the macros of a file in the test path are not callable. The `{% test %}`
  block of a rule is found in the macro path as well.
- **`ref()` and `source()` inside a rule** resolve against the project that
  calls the rule, so `should_match_model` can point at a model or a source of
  the project that uses the package.
- **On Windows, `dbt deps` cannot install a local package** without the
  privilege to create a symbolic link. A directory junction works instead:

  ```powershell
  New-Item -ItemType Junction -Path dbt_packages\dq_framework -Target dq_framework
  ```
