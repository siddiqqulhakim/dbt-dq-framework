{% test should_be_between(model, column_name, min_value, max_value, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The value of the column is between the two bounds.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null or ' ~ column_name ~ ' < ' ~ dq_framework.dq_sql_literal(min_value)
        ~ ' or ' ~ column_name ~ ' > ' ~ dq_framework.dq_sql_literal(max_value),
    threshold_pct) }}
{% endtest %}
