-- Devuelve el esquema público en el formato de supabase/esquema.txt.
-- Copia la columna "tablas" bajo "# tablas" y la columna "relaciones" (una por línea)
-- bajo "# relaciones"; después ejecuta: python3 scripts/esquema_a_diagramas.py
with cols as (
  select c.table_name, c.ordinal_position, c.column_name,
         case when c.data_type = 'USER-DEFINED' then c.udt_name
              when c.data_type like 'timestamp%' then 'timestamptz'
              when c.data_type = 'character varying' then 'text'
              else replace(c.data_type, ' ', '_') end as t,
         c.is_nullable = 'YES' as nullable
  from information_schema.columns c where c.table_schema = 'public'
), keys as (
  select tc.table_name, kcu.column_name,
         string_agg(distinct case tc.constraint_type when 'PRIMARY KEY' then 'PK'
                                                     when 'FOREIGN KEY' then 'FK'
                                                     when 'UNIQUE' then 'UK' end, ',') k
  from information_schema.table_constraints tc
  join information_schema.key_column_usage kcu
    on kcu.constraint_name = tc.constraint_name and kcu.table_schema = tc.table_schema
  where tc.table_schema = 'public' and tc.constraint_type in ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE')
  group by 1, 2
), fks as (
  select conrelid::regclass::text src, confrelid::regclass::text dst, a.attname col
  from pg_constraint co
  join pg_attribute a on a.attrelid = co.conrelid and a.attnum = co.conkey[1]
  where co.contype = 'f' and connamespace = 'public'::regnamespace
)
select
  (select string_agg(table_name || ':' || cl, E'\n' order by table_name) from (
     select c.table_name,
            string_agg(c.t || ' ' || c.column_name || coalesce(' ' || k.k, '')
                       || case when c.nullable then ' ?' else '' end, ';' order by c.ordinal_position) cl
     from cols c left join keys k using (table_name, column_name) group by c.table_name) x) as tablas,
  (select string_agg(src || '>' || dst || '>' || col, E'\n' order by src) from fks) as relaciones;
