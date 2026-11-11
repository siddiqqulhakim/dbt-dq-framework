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
{%- if rule.is_source -%}
    {%- set relation = source(rule.source_name, rule.table_name) -%}
{%- else -%}
    {%- set relation = ref(rule.model_name) -%}
{%- endif -%}
{%- if rule.where_clause -%}
    {{ '(select * from ' ~ relation ~ ' where ' ~ rule.where_clause ~ ') dbt_subquery' }}
{%- else -%}
    {{ relation }}
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
