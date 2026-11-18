-- =============================================================================
-- ClarIA 2.0 · Migración 11: Evaluador guiado (sin costo, sin IA externa)
--
-- El estudiante escribe cada ingrediente en su propio campo (rol, contexto,
-- tarea, formato, ejemplo y, en la rúbrica avanzada, técnicas). Cada campo se
-- evalúa por separado:
--   1. Calidad mínima: suficientes palabras, una oración (no una lista de
--      palabras sueltas), sin repetir palabras ni copiar otro campo.
--   2. Estructura: las reglas del criterio aplicadas solo a ese campo.
--   3. Requisitos de la misión: conceptos (con sinónimos) que ese campo debe
--      mencionar, definidos por el equipo en scenario_requirements.
-- El puntaje lo calcula el servidor; los docentes pueden revisar y corregir
-- los intentos de las misiones.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Campos y requisitos
-- -----------------------------------------------------------------------------

-- Palabras mínimas por campo.
alter table public.prompt_criteria
  add column min_words smallint not null default 3 check (min_words between 1 and 50);
update public.prompt_criteria set min_words = case criterion_key
  when 'rol' then 3 when 'contexto' then 6 when 'tarea' then 4
  when 'formato' then 3 when 'ejemplo' then 4 when 'tecnicas' then 4 else 3 end;

-- Lo que cada misión exige en cada campo. `terms` son palabras o frases
-- equivalentes (sinónimos); basta con que aparezca una. Se guardan normalizadas.
create table public.scenario_requirements (
  id          uuid primary key default gen_random_uuid(),
  scenario_id uuid not null references public.scenarios (id) on delete cascade,
  field       text not null check (field in ('rol', 'contexto', 'tarea', 'formato', 'ejemplo', 'tecnicas')),
  label       text not null check (char_length(btrim(label)) between 1 and 160),
  terms       text[] not null check (cardinality(terms) between 1 and 40),
  sort_order  smallint not null check (sort_order > 0),
  unique (scenario_id, sort_order)
);
create index scenario_requirements_scenario_id_idx on public.scenario_requirements (scenario_id);

create or replace function public.normalize_requirement_terms()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.terms := array(
    select distinct btrim(public.normalize_prompt(t))
    from unnest(new.terms) t
    where btrim(coalesce(t, '')) <> ''
  );
  if cardinality(new.terms) = 0 then
    raise exception 'El requisito «%» necesita al menos un término', new.label;
  end if;
  return new;
end;
$$;

create trigger scenario_requirements_normalize before insert or update on public.scenario_requirements
  for each row execute function public.normalize_requirement_terms();

alter table public.scenario_requirements enable row level security;
create policy "Requisitos de misiones publicadas" on public.scenario_requirements
  for select to authenticated
  using (exists (select 1 from public.scenarios s where s.id = scenario_id and s.is_published));
create policy "Admin crea contenido" on public.scenario_requirements
  for insert to authenticated with check ((select public.is_admin()));
create policy "Admin edita contenido" on public.scenario_requirements
  for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()));
create policy "Admin elimina contenido" on public.scenario_requirements
  for delete to authenticated using ((select public.is_admin()));

-- -----------------------------------------------------------------------------
-- Intentos: campos y revisión docente
-- -----------------------------------------------------------------------------

alter table public.prompt_attempts
  add column prompt_fields  jsonb not null default '{}'::jsonb,
  add column reviewed_score smallint check (reviewed_score between 0 and 100),
  add column reviewed_by    uuid references public.profiles (id) on delete set null,
  add column reviewed_at    timestamptz,
  add column review_note    text check (review_note is null or char_length(review_note) <= 500);
create index prompt_attempts_reviewed_by_idx on public.prompt_attempts (reviewed_by);

create policy "Docentes ven los intentos" on public.prompt_attempts
  for select to authenticated using ((select public.is_staff()));

-- -----------------------------------------------------------------------------
-- Apoyo
-- -----------------------------------------------------------------------------

-- Palabras de más de 3 letras (para comparar campos entre sí).
create or replace function public.word_set(p_text text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select coalesce(array_agg(distinct w), '{}')
  from regexp_split_to_table(btrim(public.normalize_prompt(p_text)), '[^a-z0-9]+') w
  where char_length(w) > 3;
$$;

-- ¿Aparece el término (palabra o frase completa) en el texto normalizado?
create or replace function public.has_term(p_norm text, p_term text)
returns boolean
language sql
immutable
set search_path = ''
as $$
  select p_norm ~ ('\y' || regexp_replace(p_term, '([.^$*+?()\[\]{}|\\])', '\\\1', 'g') || '\y');
$$;

-- -----------------------------------------------------------------------------
-- Evaluación guiada
-- -----------------------------------------------------------------------------

-- p_fields: {"rol": "...", "contexto": "...", "tarea": "...", "formato": "...",
--            "ejemplo": "...", "tecnicas": "..."}
create or replace function public.evaluate_guided_prompt(p_fields jsonb, p_scenario_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_rubric    text;
  v_composed  text;
  v_words_all integer;
  v_criteria  jsonb := '[]'::jsonb;
  v_penalties jsonb := '[]'::jsonb;
  v_total     numeric := 0;
  v_penalty   integer := 0;
  v_score     integer;
  c           record;
  p           record;
  r           record;
  v_text      text;
  v_norm      text;
  v_words     text[];
  v_count     integer;
  v_set       text[];
  v_other     text[];
  v_copy_of   text;
  v_checks    jsonb;
  v_reqs      jsonb;
  v_found     text[];
  v_req_total integer;
  v_req_met   integer;
  v_term      text;
  v_met       boolean;
  v_quality   boolean;
  v_structure text;
  v_level     text;
  v_points    numeric;
  v_feedback  text;
  v_missing   text[];
begin
  if p_fields is null or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'Formato de campos inválido' using errcode = '22023';
  end if;

  select coalesce(g.prompt_rubric, public.my_prompt_rubric()) into v_rubric
  from (select 1) x
  left join public.scenarios s on s.id = p_scenario_id
  left join public.age_groups g on g.id = s.age_group_id;

  -- Prompt completo (en el orden de la rúbrica).
  select coalesce(string_agg(btrim(p_fields ->> pc.criterion_key), E'\n' order by pc.sort_order), '')
    into v_composed
  from public.prompt_criteria pc
  where pc.rubric = v_rubric and pc.criterion_key <> 'eficiencia'
    and btrim(coalesce(p_fields ->> pc.criterion_key, '')) <> '';

  if char_length(v_composed) > 4000 then
    raise exception 'El prompt es demasiado largo (máximo 4000 caracteres)' using errcode = 'P0001';
  end if;
  v_words_all := coalesce(array_length(regexp_split_to_array(nullif(btrim(v_composed), ''), '\s+'), 1), 0);

  for c in select * from public.prompt_criteria where rubric = v_rubric order by sort_order loop
    v_checks := '[]'::jsonb;
    v_reqs := '[]'::jsonb;
    v_found := '{}';
    v_missing := '{}';

    -- Eficiencia: extensión del prompt completo.
    if c.criterion_key = 'eficiencia' then
      v_level := case when v_words_all between 15 and 120 then 'strong'
                      when v_words_all between 8 and 200 then 'partial' else 'missing' end;
      v_points := case v_level when 'strong' then c.weight when 'partial' then c.weight / 2.0 else 0 end;
      v_total := v_total + v_points;
      v_criteria := v_criteria || jsonb_build_object(
        'key', c.criterion_key, 'label', c.label, 'description', c.description,
        'weight', c.weight, 'points', round(v_points), 'level', v_level,
        'feedback', case v_level when 'strong' then c.feedback_strong
                                 when 'partial' then c.feedback_partial else c.feedback_missing end,
        'checks', jsonb_build_array(jsonb_build_object('label', 'Entre 15 y 120 palabras en total (' || v_words_all || ')', 'ok', v_level = 'strong')),
        'requirements', '[]'::jsonb, 'evidence', '[]'::jsonb, 'guided', false);
      continue;
    end if;

    v_text := btrim(coalesce(p_fields ->> c.criterion_key, ''));
    v_norm := public.normalize_prompt(v_text);
    v_words := coalesce(regexp_split_to_array(nullif(btrim(v_norm), ''), '\s+'), '{}');
    v_count := coalesce(array_length(v_words, 1), 0);
    v_set := public.word_set(v_text);

    -- 1. Calidad mínima -------------------------------------------------------
    v_checks := v_checks || jsonb_build_object(
      'label', 'Al menos ' || c.min_words || ' palabras', 'ok', v_count >= c.min_words);

    -- Oración real: con palabras de enlace, no una lista de palabras clave.
    v_checks := v_checks || jsonb_build_object(
      'label', 'Escrito como oración, no como lista de palabras',
      'ok', v_count < 4 or v_norm ~ '\y(de|la|el|que|para|en|con|un|una|los|las|y|a|por|como|mi|mis|me|lo|se|al|del|sobre|tu|tus|es|son|sea)\y');

    -- Sin repetir palabras para inflar el texto.
    v_checks := v_checks || jsonb_build_object(
      'label', 'Sin palabras repetidas de relleno',
      'ok', v_count < 6 or (select count(distinct w)::numeric / count(*) from unnest(v_words) w) >= 0.5);

    -- Sin copiar otro campo.
    v_copy_of := null;
    for p in select pc.criterion_key, pc.label from public.prompt_criteria pc
             where pc.rubric = v_rubric and pc.criterion_key not in ('eficiencia', c.criterion_key) loop
      v_other := public.word_set(p_fields ->> p.criterion_key);
      if cardinality(v_set) >= 3 and cardinality(v_other) >= 3
         and (select count(*) from unnest(v_set) w where w = any (v_other))::numeric
             / (select count(distinct w) from unnest(v_set || v_other) w) > 0.6 then
        v_copy_of := p.label;
        exit;
      end if;
    end loop;
    v_checks := v_checks || jsonb_build_object(
      'label', coalesce('No copiar el campo ' || v_copy_of, 'Texto propio (no copiado de otro campo)'),
      'ok', v_copy_of is null);

    v_quality := not exists (select 1 from jsonb_array_elements(v_checks) e where not (e ->> 'ok')::boolean);

    -- 2. Estructura del campo -------------------------------------------------
    if c.criterion_key = 'ejemplo' then
      -- El ejemplo es en sí una muestra: basta con que tenga contenido propio.
      v_structure := case when v_count >= c.min_words then 'strong' else 'missing' end;
    elsif exists (select 1 from public.prompt_rules pr
                  where pr.criterion_key = c.criterion_key and pr.kind = 'strong' and v_norm ~ pr.pattern) then
      v_structure := 'strong';
    elsif exists (select 1 from public.prompt_rules pr
                  where pr.criterion_key = c.criterion_key and pr.kind = 'partial' and v_norm ~ pr.pattern) then
      -- En el campo Rol basta con nombrar a quién debe imitar la IA.
      v_structure := case when c.criterion_key = 'rol' then 'strong' else 'partial' end;
    else
      v_structure := 'missing';
    end if;
    v_checks := v_checks || jsonb_build_object(
      'label', case c.criterion_key
        when 'rol' then 'Nombra a quién debe imitar la IA'
        when 'contexto' then 'Explica para qué y para quién es'
        when 'tarea' then 'Usa un verbo de acción claro'
        when 'formato' then 'Define una estructura o extensión concreta'
        when 'ejemplo' then 'Muestra cómo quieres la respuesta'
        when 'tecnicas' then 'Usa una técnica: restricción, paso a paso o preguntas previas'
        else 'Estructura del criterio' end,
      'ok', v_structure = 'strong');

    -- 3. Requisitos de la misión ---------------------------------------------
    v_req_total := 0;
    v_req_met := 0;
    for r in select * from public.scenario_requirements
             where scenario_id = p_scenario_id and field = c.criterion_key order by sort_order loop
      v_req_total := v_req_total + 1;
      v_met := false;
      foreach v_term in array r.terms loop
        if public.has_term(v_norm, v_term) then
          v_met := true;
          v_found := v_found || v_term;
        end if;
      end loop;
      if v_met then
        v_req_met := v_req_met + 1;
      else
        v_missing := v_missing || r.label;
      end if;
      v_reqs := v_reqs || jsonb_build_object('label', r.label, 'ok', v_met);
    end loop;

    -- Nivel del campo ----------------------------------------------------------
    if v_text = '' then
      v_level := 'missing';
      v_feedback := c.feedback_missing;
    elsif not v_quality then
      v_level := 'missing';
      v_feedback := 'Revisa este campo: ' || (
        select string_agg(lower(e ->> 'label'), '; ')
        from jsonb_array_elements(v_checks) e where not (e ->> 'ok')::boolean) || '.';
    elsif v_structure = 'strong' and v_req_met = v_req_total then
      v_level := 'strong';
      v_feedback := c.feedback_strong;
    elsif v_structure <> 'missing' or v_req_met > 0 then
      v_level := 'partial';
      v_feedback := case when cardinality(v_missing) > 0
                         then 'Te falta: ' || array_to_string(v_missing, '; ') || '.'
                         else c.feedback_partial end;
    else
      v_level := 'missing';
      v_feedback := case when cardinality(v_missing) > 0
                         then c.feedback_missing || ' Te falta: ' || array_to_string(v_missing, '; ') || '.'
                         else c.feedback_missing end;
    end if;

    v_points := case v_level when 'strong' then c.weight when 'partial' then c.weight / 2.0 else 0 end;
    v_total := v_total + v_points;
    v_criteria := v_criteria || jsonb_build_object(
      'key', c.criterion_key, 'label', c.label, 'description', c.description,
      'weight', c.weight, 'points', round(v_points), 'level', v_level, 'feedback', v_feedback,
      'checks', v_checks, 'requirements', v_reqs,
      'evidence', to_jsonb(array(select distinct unnest(v_found))), 'guided', true);
  end loop;

  -- Penalizaciones sobre el prompt completo.
  for p in select * from public.prompt_penalties
           where public.normalize_prompt(v_composed) ~ pattern order by points desc loop
    v_penalty := v_penalty + p.points;
    v_penalties := v_penalties || jsonb_build_object('label', p.label, 'points', p.points, 'tip', p.tip);
  end loop;
  v_penalty := least(v_penalty, 40);

  v_score := greatest(0, least(100, round(v_total) - v_penalty))::int;

  return jsonb_build_object(
    'score', v_score,
    'rubric', v_rubric,
    'words', v_words_all,
    'composed', v_composed,
    'criteria', v_criteria,
    'penalties', v_penalties,
    'penalty', v_penalty,
    'message', case
      when v_score >= 90 then '¡Excelente! Tu prompt es claro, completo y preciso.'
      when v_score >= 70 then '¡Buen prompt! Revisa los campos incompletos para dejarlo perfecto.'
      when v_score >= 40 then 'Vas bien. Completa los campos marcados en amarillo o rojo.'
      else 'Empieza por la tarea: di con un verbo qué quieres que haga la IA y sobre qué tema.'
    end
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Intentos de misión (reemplaza la versión de texto libre)
-- -----------------------------------------------------------------------------

drop function public.submit_prompt_attempt(uuid, text);
drop function public.evaluate_prompt(text, uuid);

create or replace function public.submit_prompt_attempt(p_scenario_id uuid, p_fields jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user     uuid := (select auth.uid());
  v_scenario public.scenarios;
  v_result   jsonb;
  v_attempt  integer;
  v_passed   boolean;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;

  select * into v_scenario from public.scenarios where id = p_scenario_id and is_published;
  if not found then
    raise exception 'Misión no encontrada' using errcode = 'P0002';
  end if;
  if not public.is_staff() and v_scenario.age_group_id is distinct from public.my_age_group_id() then
    raise exception 'Esta misión no es de tu grupo de edad' using errcode = '42501';
  end if;
  if v_scenario.lesson_id is not null and not coalesce(public.lesson_is_unlocked(v_scenario.lesson_id), false) then
    raise exception 'Esta misión aún está bloqueada' using errcode = '42501';
  end if;

  v_result := public.evaluate_guided_prompt(p_fields, p_scenario_id);
  if char_length(v_result ->> 'composed') < 10 then
    raise exception 'Completa los campos antes de enviar' using errcode = 'P0001';
  end if;
  v_passed := (v_result ->> 'score')::int >= v_scenario.passing_score;

  select coalesce(max(attempt_no), 0) + 1 into v_attempt
  from public.prompt_attempts where user_id = v_user and scenario_id = p_scenario_id;

  insert into public.prompt_attempts (user_id, scenario_id, score, attempt_no, prompt_text, prompt_fields, passed)
  values (v_user, p_scenario_id, (v_result ->> 'score')::int, v_attempt,
          v_result ->> 'composed', p_fields, v_passed);

  return v_result || jsonb_build_object('attempt_no', v_attempt, 'passed', v_passed,
                                        'passing_score', v_scenario.passing_score);
end;
$$;

-- -----------------------------------------------------------------------------
-- Revisión docente
-- -----------------------------------------------------------------------------

-- Un docente o administrador corrige el puntaje de un intento. El intento queda
-- aprobado (o no) según el puntaje revisado.
create or replace function public.review_prompt_attempt(p_attempt_id uuid, p_score integer, p_note text default null)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_passing smallint;
begin
  if not public.is_staff() then
    raise exception 'Solo docentes y administradores pueden revisar intentos' using errcode = '42501';
  end if;
  if p_score is null or p_score not between 0 and 100 then
    raise exception 'El puntaje debe estar entre 0 y 100' using errcode = 'P0001';
  end if;

  select s.passing_score into v_passing
  from public.prompt_attempts a join public.scenarios s on s.id = a.scenario_id
  where a.id = p_attempt_id;
  if v_passing is null then
    raise exception 'Intento no encontrado' using errcode = 'P0002';
  end if;

  update public.prompt_attempts
     set reviewed_score = p_score,
         reviewed_by = (select auth.uid()),
         reviewed_at = now(),
         review_note = nullif(btrim(coalesce(p_note, '')), ''),
         passed = p_score >= v_passing
   where id = p_attempt_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------

revoke execute on function
  public.word_set(text), public.has_term(text, text), public.normalize_requirement_terms(),
  public.evaluate_guided_prompt(jsonb, uuid), public.submit_prompt_attempt(uuid, jsonb),
  public.review_prompt_attempt(uuid, integer, text)
  from public, anon;
grant execute on function
  public.evaluate_guided_prompt(jsonb, uuid), public.submit_prompt_attempt(uuid, jsonb),
  public.review_prompt_attempt(uuid, integer, text)
  to authenticated;
