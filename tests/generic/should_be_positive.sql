{% test should_be_positive(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The value of the column is strictly positive.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null or ' ~ column_name ~ ' <= 0',
    threshold_pct) }}
{% endtest %}
