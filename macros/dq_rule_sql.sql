{#-
    The rows a rule checks, and the condition that breaks them.

    A rule is a generic test of tests/generic, and it holds its own logic.
    The collector asks the rule for the counts of its rows: it calls the test
    itself, with the arguments the YAML declared, and the test answers with
    the counts instead of the rows that break it.

    Nothing here has to know about a rule: the name of the test is the name of
    the rule.
-#}

{#- The relation under test, in the form the test receives it. -#}
{% macro dq_rule_model_sql(rule) -%}
{%- if execute -%}
    {%- set relation = dq_framework.dq_resolve_relation(
        model_name=none if rule.is_source else rule.model_name,
        source_name=rule.source_name if rule.is_source else none,
        table_name=rule.table_name if rule.is_source else none
    ) -%}
    {%- if rule.where_clause -%}
        {{ '(select * from ' ~ relation ~ ' where ' ~ rule.where_clause ~ ') dbt_subquery' }}
    {%- else -%}
        {{ relation }}
    {%- endif -%}
{%- endif -%}
{%- endmacro %}

{#- The counts of the rows of a rule: how many it looked at, how many broke it. -#}
{% macro dq_rule_counts_sql(rule) -%}
{%- set test_macro = dq_framework['test_' ~ rule.rule_type] -%}
{%- if not test_macro -%}
    {{ exceptions.raise_compiler_error('unknown dq rule: ' ~ rule.rule_type) }}
{%- endif -%}
{%- do context.update({'dq_collecting': true}) -%}
{%- set sql = test_macro(model=dq_framework.dq_rule_model_sql(rule), **rule.kwargs) -%}
{%- do context.update({'dq_collecting': false}) -%}
{{ return(sql) }}
{%- endmacro %}

{#- Resolves a model/seed/snapshot or source either via graph (when collecting) or ref/source (when testing). -#}
{% macro dq_resolve_relation(model_name=none, source_name=none, table_name=none) -%}
{%- if execute and context.get('dq_collecting', false) -%}
    {%- if source_name is not none -%}
        {%- set _node = graph.sources.values()
            | selectattr('source_name', 'equalto', source_name)
            | selectattr('name', 'equalto', table_name)
            | first -%}
        {%- if not _node -%}
            {{ exceptions.raise_compiler_error('Source not found in graph: ' ~ source_name ~ '.' ~ table_name) }}
        {%- endif -%}
        {{ return(adapter.Relation.create(
            database=_node.database,
            schema=_node.schema,
            identifier=_node.identifier
        )) }}
    {%- else -%}
        {%- set _node = graph.nodes.values()
            | selectattr('resource_type', 'in', ['model', 'seed', 'snapshot'])
            | selectattr('name', 'equalto', model_name)
            | first -%}
        {%- if not _node -%}
            {{ exceptions.raise_compiler_error('Model/seed not found in graph: ' ~ model_name) }}
        {%- endif -%}
        {{ return(adapter.Relation.create(
            database=_node.database,
            schema=_node.schema,
            identifier=_node.alias
        )) }}
    {%- endif -%}
{%- else -%}
    {{ return(dq_framework.dq_static_ref_or_source(model_name, source_name, table_name)) }}
{%- endif -%}
{%- endmacro %}

{#- Isolated wrapper so ref()/source() never appear in the AST during dq_collecting -#}
{% macro dq_static_ref_or_source(model_name=none, source_name=none, table_name=none) -%}
    {%- if source_name is not none -%}
        {{ return(source(source_name, table_name)) }}
    {%- else -%}
        {{ return(ref(model_name)) }}
    {%- endif -%}
{%- endmacro %}