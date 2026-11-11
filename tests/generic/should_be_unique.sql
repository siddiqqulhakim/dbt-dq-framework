{% test should_be_unique(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The column, or the listed columns, hold one row per key.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source_with_key_count(model, column_name, filter),
    'dq_key_count > 1',
    threshold_pct) }}
{% endtest %}
