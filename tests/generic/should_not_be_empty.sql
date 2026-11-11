{% test should_not_be_empty(model, column_name, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The column holds neither a NULL nor a blank value.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    column_name ~ ' is not null and trim(cast(' ~ column_name ~ ' as varchar)) = \'\'',
    threshold_pct) }}
{% endtest %}
