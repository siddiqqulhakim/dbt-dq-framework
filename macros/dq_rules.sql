{#-
    The rules of this project, read from the manifest.

    Every test is a rule: the manifest holds what the YAML declared — the rule
    name, the relation it checks, the column it looks at, the severity and the
    arguments. The collector macro turns that into the metadata of the failure
    rows and into the per-rule statistics.

    dbt writes the rows that break a rule to a table of its own, in the audit
    schema, and rewrites that table on every run. It is read only for the rules
    that broke in this run, so a table left over from an older run never
    pollutes the result.
-#}

{#- A field of a manifest entry, whether it comes as a dict or as an object. -#}
{% macro dq_field(item, key) %}
    {%- if item is mapping -%}
        {{ return(item.get(key)) }}
    {%- endif -%}
    {%- if item is not string and item is iterable -%}
        {{ return(item[key] if key in item else none) }}
    {%- endif -%}
    {{ return(item[key]) }}
{% endmacro %}

{% macro dq_manifest_rules() %}
    {%- set rules = [] -%}
    {%- for node in graph.nodes.values() -%}
        {%- if dq_framework.dq_field(node, 'resource_type') != 'test' -%}
            {%- continue -%}
        {%- endif -%}
        {%- set config = dq_framework.dq_field(node, 'config') -%}
        {%- if not dq_framework.dq_field(config, 'store_failures') -%}
            {%- continue -%}
        {%- endif -%}
        {%- set test_metadata = dq_framework.dq_field(node, 'test_metadata') -%}
        {%- set kwargs = dq_framework.dq_field(test_metadata, 'kwargs') or {} -%}
        {%- set rule_type = dq_framework.dq_field(test_metadata, 'name') or dq_framework.dq_field(node, 'name') -%}
        {%- set target = dq_framework.dq_rule_target(node) -%}
        {%- if target is none -%}
            {%- continue -%}
        {%- endif -%}
        {%- set column_name = kwargs.get('column_name', dq_framework.dq_field(node, 'column_name')) -%}
        {%- if column_name is not none and column_name is not string -%}
            {%- set column_name = column_name | join(', ') -%}
        {%- endif -%}
        {%- set rule_id = rule_type ~ '::' ~ dq_framework.dq_field(target, 'name') -%}
        {%- if column_name is not none -%}
            {%- set rule_id = rule_id ~ '::' ~ column_name -%}
        {%- endif -%}
        {%- set is_source = dq_framework.dq_field(target, 'resource_type') == 'source' -%}
        {%- set rule_kwargs = {} -%}
        {%- for key, value in kwargs.items() -%}
            {%- if key not in ['model', 'name', 'description'] -%}
                {%- do rule_kwargs.update({key: value}) -%}
            {%- endif -%}
        {%- endfor -%}
        {%- do rules.append({
              'unique_id': dq_framework.dq_field(node, 'unique_id'),
              'rule_id': rule_id,
              'rule_type': rule_type,
              'model_name': dq_framework.dq_field(target, 'name'),
              'column_name': column_name,
              'severity': dq_framework.dq_field(config, 'severity') | lower,
              'threshold_pct': kwargs.get('threshold_pct'),
              'relation': dq_framework.dq_field(target, 'relation_name'),
              'audit_relation': dq_framework.dq_field(node, 'relation_name'),
              'kwargs': rule_kwargs,
              'is_generic': test_metadata is not none,
              'is_source': is_source,
              'source_name': dq_framework.dq_field(target, 'source_name'),
              'table_name': dq_framework.dq_field(target, 'name'),
              'where_clause': dq_framework.dq_field(config, 'where'),
              'description': dq_framework.dq_field(dq_framework.dq_field(config, 'meta'), 'description')
            }) -%}
    {%- endfor -%}
    {{ return(rules) }}
{% endmacro %}

{#- The relation a rule checks: the model it is attached to, the source it reads, or, for a cross-row test, the model it looks at. -#}
{% macro dq_rule_target(node) %}
    {%- set attached = dq_framework.dq_field(node, 'attached_node') -%}
    {%- if attached is not none and attached in graph.nodes -%}
        {{ return(graph.nodes[attached]) }}
    {%- endif -%}
    {%- set dependencies = dq_framework.dq_field(dq_framework.dq_field(node, 'depends_on'), 'nodes') or [] -%}
    {%- for dependency in dependencies -%}
        {%- if dependency in graph.sources -%}
            {{ return(graph.sources[dependency]) }}
        {%- endif -%}
    {%- endfor -%}
    {%- for dependency in dependencies -%}
        {%- if dependency in graph.nodes -%}
            {{ return(graph.nodes[dependency]) }}
        {%- endif -%}
    {%- endfor -%}
    {{ return(none) }}
{% endmacro %}

{#- The outcome of the tests of this run, by test id. -#}
{% macro dq_run_status() %}
    {%- set status = {} -%}
    {%- if results is defined -%}
        {%- for result in results -%}
            {%- set node = dq_framework.dq_field(result, 'node') -%}
            {%- if node is not none and dq_framework.dq_field(node, 'resource_type') == 'test' -%}
                {%- do status.update({dq_framework.dq_field(node, 'unique_id'): dq_framework.dq_field(result, 'status')}) -%}
            {%- endif -%}
        {%- endfor -%}
    {%- endif -%}
    {{ return(status) }}
{% endmacro %}

{#-
    One row per rule: how many rows the rule looked at, how many of them broke
    it, and the score of the rule.

    The rows are counted again here instead of being read from the audit table:
    the audit table holds the failures of a rule that broke, so it cannot say
    how many rows were checked, nor how many broke a rule that stayed within
    its tolerance.
-#}
{% macro dq_rule_stats_select(rule, run_id) %}
    {%- set metadata = [
        dq_framework.dq_sql_literal(run_id) ~ ' as run_id',
        'current_timestamp as evaluated_at',
        dq_framework.dq_sql_literal(rule.rule_id) ~ ' as rule_id',
        dq_framework.dq_sql_literal(rule.rule_type) ~ ' as rule_type',
        dq_framework.dq_sql_literal(rule.model_name) ~ ' as model_name',
        dq_framework.dq_sql_literal(rule.column_name) ~ ' as column_name',
        dq_framework.dq_sql_literal(rule.severity) ~ ' as severity',
        (rule.threshold_pct if rule.threshold_pct is not none else 'null') ~ ' as threshold_pct',
        dq_framework.dq_sql_literal(rule.description) ~ ' as rule_description'
    ] -%}
    {%- if rule.is_generic -%}
        {%- set counts_sql = dq_framework.dq_rule_counts_sql(rule) -%}
        select
            {{ metadata | join(',\n            ') }},
            c.evaluated_count,
            c.broken_count,
            c.evaluated_count - c.broken_count as passed_count,
            100.0 * (c.evaluated_count - c.broken_count) / nullif(c.evaluated_count, 0) as rule_score,
            {{ dq_framework.dq_rule_status_sql(rule.threshold_pct) }} as rule_status
        from (
            {{ counts_sql }}
        ) as c
    {%- else -%}
        {#- a cross-row test: the rows it broke are known, the rows it checked are not -#}
        select
            {{ metadata | join(',\n            ') }},
            cast(null as {{ dq_framework.dq_column_type('number') }}) as evaluated_count,
            (select count(*) from {{ rule.audit_relation }}) as broken_count,
            cast(null as {{ dq_framework.dq_column_type('number') }}) as passed_count,
            cast(null as {{ dq_framework.dq_column_type('number') }}) as rule_score,
            case when (select count(*) from {{ rule.audit_relation }}) > 0 then 'FAIL' else 'PASS' end as rule_status
    {%- endif -%}
{% endmacro %}

{#- A rule passes when it stays within its tolerance, like the test that runs it. -#}
{% macro dq_rule_status_sql(threshold_pct) %}
    case when c.evaluated_count = 0 then 'NO_DATA'
        {%- if threshold_pct is none -%}
         when c.broken_count = 0 then 'PASS'
        {%- else -%}
         when 100.0 * (c.evaluated_count - c.broken_count) / nullif(c.evaluated_count, 0) >= {{ threshold_pct }} then 'PASS'
        {%- endif %}
         else 'FAIL' end
{% endmacro %}

{#- A rule that did not run in this invocation has no result to report. -#}
{% macro dq_rule_skipped_select(rule, run_id) %}
    select
        {{ dq_framework.dq_sql_literal(run_id) }} as run_id,
        current_timestamp as evaluated_at,
        {{ dq_framework.dq_sql_literal(rule.rule_id) }} as rule_id,
        {{ dq_framework.dq_sql_literal(rule.rule_type) }} as rule_type,
        {{ dq_framework.dq_sql_literal(rule.model_name) }} as model_name,
        {{ dq_framework.dq_sql_literal(rule.column_name) }} as column_name,
        {{ dq_framework.dq_sql_literal(rule.severity) }} as severity,
        {{ rule.threshold_pct if rule.threshold_pct is not none else 'null' }} as threshold_pct,
        {{ dq_framework.dq_sql_literal(rule.description) }} as rule_description,
        cast(null as {{ dq_framework.dq_column_type('number') }}) as evaluated_count,
        cast(null as {{ dq_framework.dq_column_type('number') }}) as broken_count,
        cast(null as {{ dq_framework.dq_column_type('number') }}) as passed_count,
        cast(null as {{ dq_framework.dq_column_type('number') }}) as rule_score,
        'SKIPPED' as rule_status
{% endmacro %}
