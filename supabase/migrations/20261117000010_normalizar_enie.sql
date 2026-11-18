-- =============================================================================
-- ClarIA 2.0 · Migración 10: corrige la normalización de la «ñ»
-- La tabla de translate() tenía un carácter de más y convertía «ñ» en «u»
-- («niño» → «niuo»), así que reglas como «soy un niño» no coincidían.
-- =============================================================================

create or replace function public.normalize_prompt(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select ' ' || btrim(regexp_replace(
           translate(lower(coalesce(p_text, '')), 'áéíóúüàèìòùäëïöñ', 'aeiouuaeiouaeion'),
           '\s+', ' ', 'g')) || ' ';
$$;
