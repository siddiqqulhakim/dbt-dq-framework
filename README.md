# dbt_dq_framework

A dbt package that turns data quality rules into ordinary dbt generic tests,
and keeps the results of the rules in the database.

Two things live here:

1. **The rules** — generic tests in `tests/generic/`, one file per rule
   (`should_not_be_null`, `should_be_unique`, `should_match_model`, ...). A rule
   is declared in the YAML of the model it guards, in the `data_tests:` block.
2. **The collector** — an `on-run-end` hook that turns the outcome of the run
   into three tables: the failing rows, their history, and the score of every
   rule.

The package knows nothing about the models it guards. It only knows how to say
"these rows break this rule", how to count them, and how to write the result
down.

---

## 1. What this repo is about

A dbt test passes when it returns no rows. A rule of this package is a generic
test that returns the rows that break it, and the package keeps those rows:

- **declared, not configured** — the rule lives in the `data_tests:` block of
  the model or of one of its columns, next to the model it guards;
- **tolerant** — every rule takes a `threshold_pct`: the rule only fails when
  the share of broken rows is worse than that percentage;
- **explainable** — the failing row keeps the context of the rule that broke
  it, and every rule gets a score (`evaluated_count`, `broken_count`,
  `passed_count`, `rule_score`) in `DQ_RULE_STATS`;
- **auditable** — the failures of the last run, and of every run before it, are
  in `DQ_FAILURES` and `DQ_FAILURES_HISTORY`, in the target schema.

The vocabulary of the rules:

| Test | Rule |
|---|---|
| `should_not_be_null` / `should_be_null` | the column is never / always null |
| `should_not_be_empty` | the column is neither null nor blank |
| `should_be_unique` | the column (or the listed columns) hold one row per key |
| `should_be_in` | the value is one of `values` |
| `should_be_between` / `should_be_greater_than` / `should_be_less_than` | the value is in range |
| `should_be_positive` / `should_be_non_negative` | the value is > 0 / >= 0 |
| `should_be_true` / `should_be_false` | the flag is always true / always false |
| `should_be_satisfied` | any SQL condition over the columns of the model |
| `should_be_within_sla` | the row was produced within `max_delay_seconds` of its reference date |
| `should_match_model` | every row has a matching row in another model or source, with the same values |

Every rule takes the same two optional arguments:

- `filter` — a WHERE on the relation under test;
- `threshold_pct` — the rule only fails when the share of broken rows is worse
  than this percentage. Omit it for a strict rule.

A NULL value breaks every rule that looks at a value (`in`, `between`,
`greater_than`, ...) and never breaks `should_not_be_null`. Pair the two when a
column must hold a value.

---

## 2. How the code flows

### The layout

```
macros/
  dq_assertions.sql   the helpers every rule shares: dq_assert, dq_config, dq_source...
  dq_rule_sql.sql     how a rule is asked for the counts of its rows
  dq_rules.sql        how a rule is read out of the manifest, and how its statistics are built
  store_failures.sql  the collector: the on-run-end hook and the three result tables
  dq_adapters.sql     the parts of a rule the warehouse spells its own way
tests/generic/        one file per rule
```

### At parse time

dbt reads the `data_tests:` blocks of the YAML and turns every entry into a
test node. Each node carries the name of the rule, the relation it is
attached to, the column it looks at, the severity and the arguments.

### At test time

dbt calls the macro of the rule — `dq_framework.test_should_not_be_null` and
friends — with the relation and the arguments of the YAML. Every rule of this
package has the same shape:

```sql
{% test should_not_be_null(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The column never holds a NULL value.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null',
    threshold_pct) }}
{% endtest %}
```

Three pieces:

- `dq_source(model, filter)` — the rows under test, optionally filtered;
- the violation expression — the condition that breaks a row (`column_name is null`);
- `dq_assert(...)` — the body of every rule.

`dq_assert` does three things:

1. `dq_config()` sets the config of the rule: the `dq` tag, and
   `store_failures=true, store_failures_as='table'`, so dbt keeps the failing
   rows in the database;
2. in normal mode it returns the rows that break the rule (with the
   `threshold_pct` tolerance applied) — a dbt test passes when it returns no
   rows;
3. in *collecting* mode it returns the counts instead: `evaluated_count` and
   `broken_count`.

dbt writes the failing rows to a table of its own, in the audit schema, one
table per rule, and rewrites that table on every run.

### At the end of the run

The `on-run-end` hook of the project calls `dq_framework.store_all_failures()`.
It does three things:

1. **`dq_manifest_rules()`** walks `graph.nodes` and picks the test nodes whose
   config has `store_failures` — the rules of this package. For each of them it
   resolves the relation under test (the attached model, the attached source,
   or, for a cross-row rule, the model it looks at) and builds a `rule_id` of
   the shape `rule_type::model::column`.
2. **The failures.** For every rule whose test failed, warned or errored in
   this run, `dq_failure_select` reads the audit table of that rule and the
   rows are inserted into `DQ_FAILURES` (the last run) and `DQ_FAILURES_HISTORY`
   (every run). Only the rules that broke in this run are read, so the
   leftovers of an older run never pollute the result.
3. **The statistics.** For every rule, `dq_rule_stats_select` builds one row
   with the counts and the score of the rule, and the status: `PASS`, `FAIL`,
   `NO_DATA` (the relation was empty) or `SKIPPED` (the rule did not run, or
   its model is not in the warehouse). The counts are **not** read from the
   audit table — the audit table only holds the failures of a rule that broke,
   so it cannot say how many rows were checked. Instead, `dq_rule_counts_sql`
   calls the rule itself, with the flag `dq_collecting` set, and the rule
   answers with the counts instead of the rows that break it. That is why a
   rule that stays within its tolerance still gets a score.

### The tables that are written

| Table | Content |
|---|---|
| `DQ_FAILURES` | the rows that broke a rule in the last run, with the rule they broke |
| `DQ_FAILURES_HISTORY` | the same, for every run, with the `run_id` of the run |
| `DQ_RULE_STATS` | one row per rule per run: `evaluated_count`, `broken_count`, `passed_count`, `rule_score`, `rule_status` |

They are created if they do not exist, and a column that a table does not have
yet is added, so an older table keeps its rows.

---

## 3. How to add a new generic test

A rule is a file in `tests/generic/`, named after the test. The collector finds
it on its own: `dq_rule_counts_sql` looks up the macro `test_<rule_type>` in
the package namespace, so **a new file is all it takes — there is no registry
to update**.

### A simple rule

One column, one condition. The file holds a description, the rows under test,
the condition that breaks them, and the call to `dq_assert`.

`tests/generic/should_be_even.sql`:

```sql
{% test should_be_even(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The value of the column is even.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null or ' ~ column_name ~ ' % 2 <> 0',
    threshold_pct) }}
{% endtest %}
```

The arguments of the test are the arguments the YAML gives it. `model` is
always passed by dbt; `column_name`, `filter` and `threshold_pct` are the ones
declared in the YAML.

Rules on several columns take a list: `dq_column_list(column_name)` joins it
into `a, b, c` for the SQL, and the rule id of the rule holds the joined list.

### A complex rule

A rule that needs its own SQL builds the source query itself and passes it to
`dq_assert`. The violation expression then refers to the columns of that query,
which is how `should_match_model` works: it builds a CTE that joins the model
with the other side, and adds a `violation_type` column that says what went
wrong (`missing_in_other`, `extra_in_other`, `ambiguous_other`,
`value_mismatch`).

The shape of a complex rule:

```sql
{% test should_have_a_value(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('Every row of the model holds a value in the column.') }}
{%- set source_sql -%}
select *
from {{ model }}
where {{ column_name }} is null
{%- endset -%}
{{ dq_framework.dq_assert(source_sql, '1 = 1', threshold_pct) }}
{% endtest %}
```

The rules to follow:

- **the violation expression is a boolean per row** — it is `true` for a row
  that breaks the rule. `coalesce(violation, true)` is applied, so a NULL
  violation counts as a break;
- **the source query holds every row under test**, not only the broken ones —
  the collector counts them;
- **never set the config by hand** — `dq_assert` calls `dq_config`, which
  gives the rule the `dq` tag and keeps its failures. A rule that does not go
  through `dq_assert` has to call `dq_config` itself;
- **prefix every call with the package name** (`dq_framework.dq_assert`) — dbt
  only puts the macros of the macro path in scope, and a package does not put
  its own macros in scope by their bare name;
- **`ref()` and `source()` resolve against the project that calls the rule**,
  so a rule can point at a model or a source of the project that uses the
  package.

### A rule that needs the dialect of the warehouse

The parts that the warehouse spells its own way go through the dispatcher of
`macros/dq_adapters.sql`. The package answers with the default implementation
(the Snowflake one), and the project that uses the package can override it:

```sql
{% macro duckdb__dq_delay_seconds(start_expr, end_expr) -%}
date_diff('second', {{ start_expr }}::timestamp, {{ end_expr }}::timestamp)
{%- endmacro %}
```

The dispatched pieces today are `dq_delay_seconds`, `dq_convert_timezone`,
`dq_column_type`, `dq_row_data`, `dq_catalog_columns_sql` and
`dq_catalog_relations_sql`.

---

## 4. How to use it in a dbt project

### 1. Install the package

Declare it in the `packages.yml` of the project:

```yaml
packages:
  - git: "https://github.com/siddiqqulhakim/dbt-dq-framework.git"
    revision: v1.0.0
```

A folder that is published in a git repository works the same way. A folder
that sits next to the project works as a local package:

```yaml
packages:
  - local: ../dbt_dq_framework
```

Then install it:

```bash
dbt deps
```

### 2. Wire the collector

The results are collected by a hook, so the project needs one `on-run-end` hook
in its `dbt_project.yml`:

```yaml
on-run-end:
  - "{{ dq_framework.store_all_failures() }}"
```

The macro can also be called straight from the package
(`{{ dq_framework.store_all_failures() }}`); a project that does not want the
hook to depend on the name of the package can wrap it in a macro of its own,
for example `macros/dq_hooks.sql`:

```sql
{% macro store_all_failures() %}
    {{ dq_framework.store_all_failures() }}
{% endmacro %}
```

and use `{{ store_all_failures() }}` in the hook.

The rules of the package keep their failures on their own: the config call of
`dq_config` turns `store_failures` on for every rule, so the project does not
have to set it.

### 3. The audit schema

dbt writes the failing rows to a table of its own, in the audit schema
(`DBT_TEST__AUDIT` by default, one table per rule). The role that runs dbt
must be allowed to create and write in it:

```sql
create schema if not exists <DATABASE>.DBT_TEST__AUDIT
  authorization '<ROLE>';
```

Another schema can be used with the `store_failures_schema` config, set in the
`config:` block of the rule:

```yaml
      - dq_framework.should_not_be_null:
          arguments:
            column_name: AREA
          config:
            store_failures_schema: MY_AUDIT
```

### 4. Declare the rules

A rule is a generic test of the package, called from the `data_tests:` block of
the model (or of one of its columns). The name of the package comes first:

```yaml
models:
  - name: gld_executive_daily
    data_tests:
      - dq_framework.should_be_unique:
          arguments:
            column_name: [AREA, KEY, DATE_REPORTED]
      - dq_framework.should_not_be_null:
          arguments:
            column_name: AREA
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

The arguments of a rule go under `arguments:`, and the config of the rule (the
severity, the `where` filter, a description) goes under `config:`.

### 5. Run it

```bash
dbt build
```

The tests run, the failing rows are written to the audit schema, and the hook
fills `DQ_FAILURES`, `DQ_FAILURES_HISTORY` and `DQ_RULE_STATS`.

Every rule of the package carries the `dq` tag, so the whole suite runs
read-only with:

```bash
dbt test --select tag:dq
```

### Severity

`severity: error` fails the build, `severity: warn` only reports. The rules
that guard the business key are errors; the tolerance rules (accuracy,
consistency, validity, timeliness) are warnings at their `threshold_pct`, so a
breach is reported without stopping the pipeline.

---

## Notes for anyone who works on the package

- **The rules live in `tests/generic/`, one file per rule.** dbt registers the
  `{% test %}` block of a file in the test path as a generic test of the
  package; the macros of a file in the test path are not callable by their
  bare name, which is why every call inside a rule is prefixed with
  `dq_framework.`.
- **The collector resolves the rule by name.** `dq_rule_counts_sql` looks up
  `test_<rule_type>` in the package namespace, so a new rule file is picked up
  without touching the collector.
- **The counts are asked of the rule itself**, not read from the audit table:
  the flag `dq_collecting` makes `dq_assert` answer with the counts instead of
  the rows that break the rule.
- **The config of a rule can only be set in the body of the test.** The
  `data_tests:` block of the `dbt_project.yml` of the package that defines the
  test never reaches it, and the project that uses the package cannot target
  "the tests of this package" either. That is why `dq_config` lives in
  `dq_assertions.sql` and every rule goes through `dq_assert`.
- **On Windows, `dbt deps` cannot install a local package** without the
  privilege to create a symbolic link. A directory junction works instead:

  ```powershell
  New-Item -ItemType Junction -Path dbt_packages\dq_framework -Target ..\dbt_dq_framework
  ```
