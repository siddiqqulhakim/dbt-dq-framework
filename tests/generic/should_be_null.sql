{% test should_be_null(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The column always holds a NULL value.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is not null',
    threshold_pct) }}
{% endtest %}
