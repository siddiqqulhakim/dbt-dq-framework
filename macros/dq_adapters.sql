{#-
    The parts of a rule that the warehouse spells its own way.

    A rule that needs such a part calls the dispatcher, and the adapter of the
    project answers it: `duckdb__dq_delay_seconds` for duckdb, and the
    `default__` one for everything else.
-#}

{% macro dq_delay_seconds(start_expr, end_expr) -%}
{{ adapter.dispatch('dq_delay_seconds', 'dq_framework')(start_expr, end_expr) }}
{%- endmacro %}

{% macro default__dq_delay_seconds(start_expr, end_expr) -%}
datediff(second, {{ start_expr }}::timestamp, {{ end_expr }}::timestamp)
{%- endmacro %}

{% macro dq_convert_timezone(column, timezone) -%}
{{ adapter.dispatch('dq_convert_timezone', 'dq_framework')(column, timezone) }}
{%- endmacro %}

{% macro default__dq_convert_timezone(column, timezone) -%}
convert_timezone({{ dq_framework.dq_sql_literal(timezone) }}, {{ column }})
{%- endmacro %}

{#- The type of a column of the tables of the collector. -#}
{% macro dq_column_type(name) -%}
{{ adapter.dispatch('dq_column_type', 'dq_framework')(name) }}
{%- endmacro %}

{% macro default__dq_column_type(name) -%}
{{ name }}
{%- endmacro %}

{#- The row of a failure, as the warehouse holds it. -#}
{% macro dq_row_data() -%}
{{ adapter.dispatch('dq_row_data', 'dq_framework')() }}
{%- endmacro %}

{% macro default__dq_row_data() -%}
object_construct(*)
{%- endmacro %}

{#- The columns a table of the target schema already has. -#}
{% macro dq_catalog_columns_sql(table_name) -%}
{{ adapter.dispatch('dq_catalog_columns_sql', 'dq_framework')(table_name) }}
{%- endmacro %}

{% macro default__dq_catalog_columns_sql(table_name) -%}
select column_name
from {{ target.database }}.information_schema.columns
where table_schema = '{{ target.schema }}' and table_name = '{{ table_name }}'
{%- endmacro %}

{#- The tables that exist, as SCHEMA.TABLE. -#}
{% macro dq_catalog_relations_sql() -%}
{{ adapter.dispatch('dq_catalog_relations_sql', 'dq_framework')() }}
{%- endmacro %}

{% macro default__dq_catalog_relations_sql() -%}
select table_schema, table_name
from {{ target.database }}.information_schema.tables
{%- endmacro %}
