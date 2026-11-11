{% test should_not_be_null(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The column never holds a NULL value.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null',
    threshold_pct) }}
{% endtest %}
