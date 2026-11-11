{#-
    The helpers shared by the rules of tests/generic.

    A dbt test passes when it returns no rows, so every rule returns the rows
    that break it. `threshold_pct` keeps the tolerance: the rows are only
    returned when the share of broken rows is worse than that percentage.

    Every rule takes the same optional arguments:
      filter         filter on the relation under test
      threshold_pct  the rule only fails when the share of broken rows is
                     worse than this percentage (omit it for a strict rule)
-#}

{% macro dq_sql_literal(value) -%}
    {%- if value is none -%}
        null
    {%- elif value is boolean -%}
        {{ 'true' if value else 'false' }}
    {%- elif value is number -%}
        {{ value }}
    {%- else -%}
        '{{ (value | string).replace("'", "''") }}'
    {%- endif -%}
{%- endmacro %}

{% macro dq_value_list(values) -%}
    {%- for value in values -%}
        {{ dq_framework.dq_sql_literal(value) }}{{ ', ' if not loop.last }}
    {%- endfor -%}
{%- endmacro %}

{#- A test argument may be one column or a list of columns; returns them joined. -#}
{% macro dq_column_list(column_name) -%}
    {%- if column_name is string -%}
        {{ column_name }}
    {%- else -%}
        {{ column_name | join(', ') }}
    {%- endif -%}
{%- endmacro %}

{#- The rows under test, optionally filtered. -#}
{% macro dq_source(relation, filter=none) -%}
select *
from {{ relation }}
{%- if filter is not none %}
where {{ filter }}
{%- endif %}
{%- endmacro %}

{#- The rows under test, with the number of rows that share their key. -#}
{% macro dq_source_with_key_count(relation, column_name, filter=none) -%}
select *,
       count(*) over (partition by {{ dq_framework.dq_column_list(column_name) }}) as dq_key_count
from {{ relation }}
{%- if filter is not none %}
where {{ filter }}
{%- endif %}
{%- endmacro %}

{#-
    The config every rule of this package carries.

    A generic test is configured by the project that declares it: the
    `data_tests:` block of the dbt_project.yml of the package that defines the
    test never reaches it, and the project that uses the package cannot target
    "the tests of this package" either. The config call in the body of the test
    is the only place that works, so it lives here, once, and every rule goes
    through `dq_assert`.

    store_failures keeps the rows that break a rule in the database: dbt writes
    them to a table of its own, in the audit schema, and the on-run-end hook of
    the project collects them into DQ_FAILURES.
-#}
{% macro dq_config() -%}
{{ config(tags=['dq'], store_failures=true, store_failures_as='table') }}
{%- endmacro %}

{#-
    What a rule says about itself. It lands in the meta of the rule, and the
    collector writes it next to the score of the rule.
-#}
{% macro dq_description(text) -%}
{{ config(meta={'description': text}) }}
{%- endmacro %}

{#-
    The collector counts the rows of a rule by calling the rule itself: it sets
    this flag, and the rule answers with the counts instead of the rows that
    break it.
-#}
{% macro dq_collecting() -%}
{{ return(context.get('dq_collecting', false)) }}
{%- endmacro %}

{#-
    The body of every rule.

    The rows that break the rule, and the config of the rule that keeps them,
    are the same for every rule of this package.
-#}
{% macro dq_assert(source_sql, violation_sql, threshold_pct=none) %}
    {{- dq_framework.dq_config() -}}
    {%- if dq_framework.dq_collecting() -%}
select
    (select count(*) from ({{ source_sql }}) as dq_rows) as evaluated_count,
    (select count(*) from ({{ source_sql }}) as dq_rows where coalesce({{ violation_sql }}, true)) as broken_count
    {%- elif threshold_pct is none -%}
select *
from (
    {{ source_sql }}
) as dq_rows
where coalesce({{ violation_sql }}, true)
    {%- else -%}
with dq_rows as (
    {{ source_sql }}
), dq_broken as (
    select *
    from dq_rows
    where coalesce({{ violation_sql }}, true)
), dq_stats as (
    select
        (select count(*) from dq_rows)   as total_rows,
        (select count(*) from dq_broken) as broken_rows
)
select dq_broken.*
from dq_broken
cross join dq_stats
where dq_stats.total_rows > 0
  and 100.0 * (dq_stats.total_rows - dq_stats.broken_rows) / dq_stats.total_rows < {{ threshold_pct }}
    {%- endif -%}
{% endmacro %}
