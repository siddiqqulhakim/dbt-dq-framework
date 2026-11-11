{% test should_be_true(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The flag of the column is always true.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is null or ' ~ column_name ~ ' <> true',
    threshold_pct) }}
{% endtest %}
