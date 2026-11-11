{% test should_be_within_sla(model, start_column, end_column, max_delay_seconds,
                             start_timezone=none, end_timezone=none, not_before=none,
                             not_before_var=none, filter=none, threshold_pct=none) %}
{{ dq_framework.dq_description('The row was produced within the delay allowed by the SLA.') }}
{%- set not_before = var(not_before_var) if not_before_var is not none else not_before -%}
{%- set start_expr = dq_framework.dq_convert_timezone(start_column, start_timezone)
                     if start_timezone is not none else start_column -%}
{%- set end_expr = dq_framework.dq_convert_timezone(end_column, end_timezone)
                   if end_timezone is not none else end_column -%}
{%- set delay_expr = dq_framework.dq_delay_seconds(start_expr, end_expr) -%}
{%- set exempt_expr = start_column ~ '::date <= ' ~ dq_framework.dq_sql_literal(not_before) ~ '::date'
                      if not_before is not none else 'false' -%}
{{ dq_framework.dq_assert(
    dq_framework.dq_source(model, filter),
    'not ((' ~ exempt_expr ~ ') or (' ~ delay_expr ~ ' between 0 and ' ~ dq_framework.dq_sql_literal(max_delay_seconds) ~ '))',
    threshold_pct) }}
{% endtest %}
