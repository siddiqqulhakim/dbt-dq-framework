{% test should_be_greater_than(model, column_name, value, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The value of the column is greater than the bound.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null or ' ~ column_name ~ ' <= ' ~ dq_framework.dq_sql_literal(value),
    threshold_pct) }}
{% endtest %}
