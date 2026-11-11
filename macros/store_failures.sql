{#-
    The data quality results of the run, in the database.

    dbt writes the rows that break a rule to a table of its own, in the audit
    schema (one table per test, enabled with `store_failures` in
    dbt_project.yml). This macro collects them into three tables:

      DQ_FAILURES          the rows that broke a rule in this run, with the
                           rule they broke
      DQ_FAILURES_HISTORY  the same, for every run
      DQ_RULE_STATS        one row per rule: how many rows it checked, how
                           many broke it and the score of the rule

    It runs as an on-run-end hook, after the tests, so the tables hold the
    results of the run that just finished. The audit table of a rule is read
    only when that rule broke in this run, so the leftovers of an older run
    never end up in the result.
-#}

{% macro store_all_failures() %}
    {%- if not execute -%}
        {#- the hook is rendered while parsing too, there is nothing to store yet -#}
        {{ return('select 1') }}
    {%- endif -%}
    {%- set rules = dq_framework.dq_manifest_rules() -%}
    {%- set status = dq_framework.dq_run_status() -%}
    {%- set run_id = invocation_id -%}
    {%- set existing = dq_framework.dq_existing_relations() -%}
    {%- set failures = [] -%}
    {%- set stats = [] -%}
    {%- for rule in rules -%}
        {%- set state = status.get(rule.unique_id, 'skipped') -%}
        {%- if state in ['fail', 'warn', 'error'] -%}
            {%- do failures.append(dq_framework.dq_failure_select(rule, run_id)) -%}
        {%- endif -%}
        {%- if state == 'skipped' or not dq_framework.dq_relation_exists(rule.relation, existing) -%}
            {%- do stats.append(dq_framework.dq_rule_skipped_select(rule, run_id)) -%}
        {%- else -%}
            {%- do stats.append(dq_framework.dq_rule_stats_select(rule, run_id)) -%}
        {%- endif -%}
    {%- endfor -%}
    {%- set failures_sql = failures | join('\nunion all\n') -%}
    {%- set stats_sql = stats | join('\nunion all\n') -%}
    {%- set failure_columns = dq_framework.dq_failure_columns() -%}
    {%- set stats_columns = dq_framework.dq_stats_columns() -%}
    {%- set sql -%}
        {{ dq_framework.dq_create_table('DQ_FAILURES', failure_columns) }}
        delete from {{ target.database }}.{{ target.schema }}.DQ_FAILURES;
        {% if failures_sql %}
        insert into {{ target.database }}.{{ target.schema }}.DQ_FAILURES (
            {{ failure_columns | map(attribute=0) | join(', ') }}
        )
        {{ failures_sql }};
        {% endif %}

        {{ dq_framework.dq_create_table('DQ_FAILURES_HISTORY', failure_columns) }}
        {% if failures_sql %}
        insert into {{ target.database }}.{{ target.schema }}.DQ_FAILURES_HISTORY (
            {{ failure_columns | map(attribute=0) | join(', ') }}
        )
        {{ failures_sql }};
        {% endif %}

        {{ dq_framework.dq_create_table('DQ_RULE_STATS', stats_columns) }}
        insert into {{ target.database }}.{{ target.schema }}.DQ_RULE_STATS (
            {{ stats_columns | map(attribute=0) | join(', ') }}
        )
        {{ stats_sql }};
    {%- endset -%}
    {{ log('stored the failures of ' ~ failures | length ~ ' rules and the score of ' ~ stats | length ~ ' rules for run ' ~ run_id, info=True) }}
    {{ return(sql) }}
{% endmacro %}

{#- The rows that broke a rule, with the rule they broke. -#}
{% macro dq_failure_select(rule, run_id) %}
    select
        {{ dq_framework.dq_sql_literal(run_id) }} as run_id,
        current_timestamp as failed_at,
        {{ dq_framework.dq_sql_literal(rule.rule_id) }} as rule_id,
        {{ dq_framework.dq_sql_literal(rule.rule_type) }} as rule_type,
        {{ dq_framework.dq_sql_literal(rule.model_name) }} as model_name,
        {{ dq_framework.dq_sql_literal(rule.column_name) }} as column_name,
        {{ dq_framework.dq_sql_literal(rule.severity) }} as severity,
        {{ rule.threshold_pct if rule.threshold_pct is not none else 'null' }} as threshold_pct,
        {{ dq_framework.dq_row_data() }} as row_data
    from {{ rule.audit_relation }} as t
{% endmacro %}

{% macro dq_failure_columns() %}
    {{ return([
        ('run_id', dq_framework.dq_column_type('varchar')),
        ('failed_at', dq_framework.dq_column_type('timestamp_ntz')),
        ('rule_id', dq_framework.dq_column_type('varchar')),
        ('rule_type', dq_framework.dq_column_type('varchar')),
        ('model_name', dq_framework.dq_column_type('varchar')),
        ('column_name', dq_framework.dq_column_type('varchar')),
        ('severity', dq_framework.dq_column_type('varchar')),
        ('threshold_pct', dq_framework.dq_column_type('number')),
        ('row_data', dq_framework.dq_column_type('variant'))
    ]) }}
{% endmacro %}

{% macro dq_stats_columns() %}
    {{ return([
        ('run_id', dq_framework.dq_column_type('varchar')),
        ('evaluated_at', dq_framework.dq_column_type('timestamp_ntz')),
        ('rule_id', dq_framework.dq_column_type('varchar')),
        ('rule_type', dq_framework.dq_column_type('varchar')),
        ('model_name', dq_framework.dq_column_type('varchar')),
        ('column_name', dq_framework.dq_column_type('varchar')),
        ('severity', dq_framework.dq_column_type('varchar')),
        ('threshold_pct', dq_framework.dq_column_type('number')),
        ('rule_description', dq_framework.dq_column_type('varchar')),
        ('evaluated_count', dq_framework.dq_column_type('number')),
        ('broken_count', dq_framework.dq_column_type('number')),
        ('passed_count', dq_framework.dq_column_type('number')),
        ('rule_score', dq_framework.dq_column_type('number')),
        ('rule_status', dq_framework.dq_column_type('varchar'))
    ]) }}
{% endmacro %}

{#- The table, with the columns it does not have yet: an older table keeps its rows. -#}
{% macro dq_create_table(table_name, columns) %}
    {%- set existing = dq_framework.dq_existing_columns(table_name) -%}
    create table if not exists {{ target.database }}.{{ target.schema }}.{{ table_name }} (
        {%- for name, data_type in columns %}
        {{ name }} {{ data_type }}{{ ', ' if not loop.last }}
        {%- endfor %}
    );
    {%- for name, data_type in columns %}
    {%- if name not in existing %}
    alter table {{ target.database }}.{{ target.schema }}.{{ table_name }} add column if not exists {{ name }} {{ data_type }};
    {%- endif %}
    {%- endfor %}
{% endmacro %}

{% macro dq_existing_columns(table_name) %}
    {%- set columns = [] -%}
    {%- set result = run_query(dq_framework.dq_catalog_columns_sql(table_name)) -%}
    {%- for row in result.rows -%}
        {%- do columns.append(row[0]) -%}
    {%- endfor -%}
    {{ return(columns) }}
{% endmacro %}

{#- The tables that exist, as SCHEMA.TABLE, to skip a rule whose model is not there. -#}
{% macro dq_existing_relations() %}
    {%- set relations = [] -%}
    {%- set result = run_query(dq_framework.dq_catalog_relations_sql()) -%}
    {%- for row in result.rows -%}
        {%- do relations.append((row[0] ~ '.' ~ row[1]) | upper) -%}
    {%- endfor -%}
    {{ return(relations) }}
{% endmacro %}

{% macro dq_relation_exists(relation, existing) %}
    {%- set parts = relation.split('.') -%}
    {%- if parts | length < 2 -%}
        {{ return(false) }}
    {%- endif -%}
    {%- set name = (parts[parts | length - 2] ~ '.' ~ parts[parts | length - 1]) | replace('"', '') | upper -%}
    {{ return(name in existing) }}
{% endmacro %}
