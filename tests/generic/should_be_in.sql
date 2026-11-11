{% test should_be_in(model, column_name, values, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The value of the column is one of the allowed values.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null or not (' ~ column_name ~ ' in (' ~ dq_framework.dq_value_list(values) ~ '))',
    threshold_pct) }}
{% endtest %}
