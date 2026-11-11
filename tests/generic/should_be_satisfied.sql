{% test should_be_satisfied(model, condition, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The condition holds for every row of the model.') }}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    'not (' ~ condition ~ ')',
    threshold_pct) }}
{% endtest %}
