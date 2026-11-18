-- =============================================================================
-- ClarIA 2.0 · Migración 12: evaluador guiado más difícil de engañar
-- Ajustes tras probar trampas:
--   * Un campo que no menciona ninguno de los requisitos de la misión vale 0
--     (antes, buena forma sobre otro tema daba la mitad de puntos).
--   * Si el prompt cumple menos de la mitad de los requisitos de la misión, el
--     puntaje se limita a 40 (no puede aprobar un prompt de otro tema).
--   * Ninguna palabra puede repetirse 3 veces o más para inflar un campo.
-- =============================================================================

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
  v_all_reqs  integer := 0;
  v_all_met   integer := 0;
  v_off_topic boolean := false;
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

    -- Sin repetir palabras para inflar el texto: ninguna palabra 3 veces o más
    -- y al menos la mitad de las palabras distintas.
    v_checks := v_checks || jsonb_build_object(
      'label', 'Sin palabras repetidas de relleno',
      'ok', not exists (select 1 from unnest(v_words) w where char_length(w) > 3
                        group by w having count(*) >= 3)
            and (v_count < 4 or (select count(distinct w)::numeric / count(*) from unnest(v_words) w) >= 0.5));

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
    v_all_reqs := v_all_reqs + v_req_total;
    v_all_met := v_all_met + v_req_met;

    -- Nivel del campo ----------------------------------------------------------
    if v_text = '' then
      v_level := 'missing';
      v_feedback := c.feedback_missing;
    elsif not v_quality then
      v_level := 'missing';
      v_feedback := 'Revisa este campo: ' || (
        select string_agg(lower(e ->> 'label'), '; ')
        from jsonb_array_elements(v_checks) e where not (e ->> 'ok')::boolean) || '.';
    elsif v_req_total > 0 and v_req_met = 0 then
      -- Buena forma, pero no habla de lo que pide la misión.
      v_level := 'missing';
      v_feedback := 'Este campo no corresponde a la misión. Te falta: ' || array_to_string(v_missing, '; ') || '.';
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

  -- Si cumple menos de la mitad de lo que pide la misión, no puede aprobar.
  if v_all_reqs > 0 and v_all_met::numeric / v_all_reqs < 0.5 then
    v_off_topic := true;
    v_score := least(v_score, 40);
  end if;

  return jsonb_build_object(
    'score', v_score,
    'rubric', v_rubric,
    'words', v_words_all,
    'composed', v_composed,
    'criteria', v_criteria,
    'penalties', v_penalties,
    'penalty', v_penalty,
    'requirements_met', v_all_met,
    'requirements_total', v_all_reqs,
    'off_topic', v_off_topic,
    'message', case
      when v_off_topic then 'Tu prompt no corresponde a esta misión: revisa el objetivo y menciona lo que se pide en cada campo.'
      when v_score >= 90 then '¡Excelente! Tu prompt es claro, completo y preciso.'
      when v_score >= 70 then '¡Buen prompt! Revisa los campos incompletos para dejarlo perfecto.'
      when v_score >= 40 then 'Vas bien. Completa los campos marcados en amarillo o rojo.'
      else 'Empieza por la tarea: di con un verbo qué quieres que haga la IA y sobre qué tema.'
    end
  );
end;
$$;
