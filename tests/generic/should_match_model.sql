{% test should_match_model(model,
                           other_model=none,
                           other_source=none,
                           other_table=none,
                           key_columns=[],
                           compare_columns=[],
                           other_key_columns=none,
                           other_compare_columns=none,
                           other_where=none,
                           latest_by=none,
                           match_both_ways=false,
                           filter=none,
                           threshold_pct=none) %}
{{ dq_framework.dq_description('Every row of the model has a matching row in another model or source, with the same values.') }}
{%- if other_model is none and other_source is none %}
{{ exceptions.raise_compiler_error('should_match_model needs other_model or other_source and other_table') }}
{%- endif %}
{%- if key_columns | length == 0 %}
{{ exceptions.raise_compiler_error('should_match_model needs key_columns') }}
{%- endif %}
{%- set other_relation = source(other_source, other_table) if other_source is not none else ref(other_model) -%}
{%- set other_keys = key_columns if other_key_columns is none else other_key_columns -%}
{%- set other_compares = compare_columns if other_compare_columns is none else other_compare_columns -%}
{%- set keys_sql = key_columns | join(', ') -%}
{%- set pick_sql = '__dq_order_by desc' if latest_by is not none else keys_sql -%}
{%- set source_sql -%}
with dq_other as (
    select
    {%- for name in key_columns %}
        {{ other_keys[loop.index0] }} as {{ name }},
    {%- endfor %}
    {%- for name in compare_columns %}
        {{ other_compares[loop.index0] }} as {{ name }},
    {%- endfor %}
    {%- if latest_by is not none %}
        {{ latest_by }} as __dq_order_by,
    {%- endif %}
    1 as __dq_present
    from {{ other_relation }}
    {%- if other_where is not none %}
    where {{ other_where }}
    {%- endif %}
), dq_other_ranked as (
    select *
    from dq_other
    {%- if latest_by is not none %}
    qualify rank() over (partition by {{ keys_sql }} order by __dq_order_by desc) = 1
    {%- endif %}
), dq_other_counted as (
    select *,
           count(*) over (partition by {{ keys_sql }}) as dq_match_count,
           row_number() over (partition by {{ keys_sql }} order by {{ pick_sql }}) as __dq_pick
    from dq_other_ranked
), dq_other_keyed as (
    select *
    from dq_other_counted
    where __dq_pick = 1
), dq_model as (
    select *, 1 as __dq_model_present
    from {{ model }}
    {%- if filter is not none %}
    where {{ filter }}
    {%- endif %}
), dq_joined as (
    select
        m.__dq_model_present as m_present,
        o.__dq_present       as o_present,
        o.dq_match_count     as dq_match_count,
        {%- for name in key_columns %}
        m.{{ name }} as m_{{ name }},
        {%- endfor %}
        {%- for name in compare_columns %}
        m.{{ name }} as m_{{ name }},
        o.{{ name }} as o_{{ name }},
        {%- endfor %}
    from dq_model m
    {{ 'full outer' if match_both_ways else 'left' }} join dq_other_keyed o
      on {% for name in key_columns %}
        (coalesce(m.{{ name }} = o.{{ name }}, false) or (m.{{ name }} is null and o.{{ name }} is null))
        {%- if not loop.last %} and {% endif %}
        {%- endfor %}
), dq_resolved as (
    select *,
        case
            when m_present is null then 'extra_in_other'
            when o_present is null then 'missing_in_other'
            when dq_match_count > 1 then 'ambiguous_other'
            {%- if compare_columns | length > 0 %}
            when {% for name in compare_columns %}
                not (coalesce(m_{{ name }} = o_{{ name }}, false) or (m_{{ name }} is null and o_{{ name }} is null))
                {%- if not loop.last %} or {% endif %}
                {%- endfor %}
            then 'value_mismatch'
            {%- endif %}
            else null
        end as violation_type
    from dq_joined
)
select * from dq_resolved
{%- endset -%}
{{ dq_framework.dq_assert(source_sql, 'violation_type is not null', threshold_pct) }}
{% endtest %}
