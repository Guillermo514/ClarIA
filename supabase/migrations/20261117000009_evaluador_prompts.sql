-- =============================================================================
-- ClarIA 2.0 · Migración 9: Evaluador de prompts
--
-- Califica prompts con reglas (sin IA externa) según una rúbrica por edad:
--   * básica (8 a 14 años): los 5 ingredientes de la lección 5.3, 20 pts cada uno.
--   * avanzada (15+): los 5 ingredientes (70 pts) + eficiencia y técnicas
--     avanzadas de la lección 7.1 (30 pts).
-- Pedir que la IA haga la tarea resta puntos en ambas.
-- Las misiones viven en `scenarios`; las de las lecciones 5.4 y 7.1 son requisito
-- para completar esas lecciones (70+ puntos).
-- Las reglas son datos: un administrador puede ajustarlas sin cambiar código.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Rúbricas y reglas
-- -----------------------------------------------------------------------------

alter table public.age_groups
  add column prompt_rubric text not null default 'basica'
  check (prompt_rubric in ('basica', 'avanzada'));
update public.age_groups set prompt_rubric = 'avanzada' where min_age >= 15;

-- Criterios de cada rúbrica, con su peso y la retroalimentación por nivel de logro.
create table public.prompt_criteria (
  id               uuid primary key default gen_random_uuid(),
  rubric           text not null check (rubric in ('basica', 'avanzada')),
  criterion_key    text not null check (criterion_key ~ '^[a-z_]{2,30}$'),
  label            text not null check (char_length(btrim(label)) between 1 and 60),
  description      text not null check (char_length(btrim(description)) between 1 and 300),
  weight           smallint not null check (weight between 1 and 100),
  sort_order       smallint not null check (sort_order > 0),
  feedback_strong  text not null check (char_length(btrim(feedback_strong)) between 1 and 400),
  feedback_partial text not null check (char_length(btrim(feedback_partial)) between 1 and 400),
  feedback_missing text not null check (char_length(btrim(feedback_missing)) between 1 and 400),
  unique (rubric, criterion_key),
  unique (rubric, sort_order)
);

-- Patrones (expresiones regulares de PostgreSQL) que se buscan en el prompt ya
-- normalizado: minúsculas, sin acentos y con espacios simples.
create table public.prompt_rules (
  id            uuid primary key default gen_random_uuid(),
  criterion_key text not null check (criterion_key ~ '^[a-z_]{2,30}$'),
  kind          text not null check (kind in ('strong', 'partial')),
  pattern       text not null check (char_length(pattern) between 2 and 1000),
  unique (criterion_key, kind, pattern)
);

-- Penalizaciones por pedir que la IA haga el trabajo del estudiante.
create table public.prompt_penalties (
  id      uuid primary key default gen_random_uuid(),
  label   text not null unique check (char_length(btrim(label)) between 1 and 120),
  pattern text not null check (char_length(pattern) between 2 and 1000),
  points  smallint not null check (points between 1 and 100),
  tip     text not null check (char_length(btrim(tip)) between 1 and 300)
);

-- Valida que los patrones sean expresiones regulares correctas.
create or replace function public.check_prompt_pattern()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  perform '' ~ new.pattern;
  return new;
exception when invalid_regular_expression then
  raise exception 'Patrón inválido: %', new.pattern;
end;
$$;

create trigger prompt_rules_check_pattern before insert or update on public.prompt_rules
  for each row execute function public.check_prompt_pattern();
create trigger prompt_penalties_check_pattern before insert or update on public.prompt_penalties
  for each row execute function public.check_prompt_pattern();

-- -----------------------------------------------------------------------------
-- Misiones (scenarios) e intentos
-- -----------------------------------------------------------------------------

alter table public.scenarios
  add column age_group_id  uuid references public.age_groups (id),
  add column lesson_id     uuid unique references public.lessons (id) on delete set null,
  add column passing_score smallint not null default 70 check (passing_score between 1 and 100),
  add column sort_order    smallint not null default 1 check (sort_order > 0);
create index scenarios_age_group_id_idx on public.scenarios (age_group_id);

alter table public.prompt_attempts
  add column prompt_text text not null default '' check (char_length(prompt_text) <= 4000),
  add column passed boolean not null default false;

-- Los intentos solo se registran con submit_prompt_attempt() (califica el servidor).
drop policy "Registrar intento de prompt" on public.prompt_attempts;
revoke insert, update, delete on public.prompt_attempts from anon, authenticated;

-- -----------------------------------------------------------------------------
-- RLS de las tablas nuevas
-- -----------------------------------------------------------------------------

alter table public.prompt_criteria enable row level security;
alter table public.prompt_rules enable row level security;
alter table public.prompt_penalties enable row level security;

create policy "Rúbrica visible" on public.prompt_criteria
  for select to authenticated using (true);
create policy "Reglas solo admin" on public.prompt_rules
  for select to authenticated using ((select public.is_admin()));
create policy "Penalizaciones solo admin" on public.prompt_penalties
  for select to authenticated using ((select public.is_admin()));

do $$
declare
  t text;
begin
  foreach t in array array['prompt_criteria', 'prompt_rules', 'prompt_penalties'] loop
    execute format('create policy "Admin crea contenido" on public.%I for insert to authenticated with check ((select public.is_admin()))', t);
    execute format('create policy "Admin edita contenido" on public.%I for update to authenticated using ((select public.is_admin())) with check ((select public.is_admin()))', t);
    execute format('create policy "Admin elimina contenido" on public.%I for delete to authenticated using ((select public.is_admin()))', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Motor de evaluación
-- -----------------------------------------------------------------------------

create or replace function public.normalize_prompt(p_text text)
returns text
language sql
immutable
set search_path = ''
as $$
  select ' ' || btrim(regexp_replace(
           translate(lower(coalesce(p_text, '')), 'áéíóúüàèìòùäëïöñ', 'aeiouuaeiouaeioun'),
           '\s+', ' ', 'g')) || ' ';
$$;

-- Rúbrica que le toca al usuario actual (la avanzada para staff).
create or replace function public.my_prompt_rubric()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.is_staff() then 'avanzada'
              else coalesce((select g.prompt_rubric from public.age_groups g
                             where g.id = public.my_age_group_id()), 'basica') end;
$$;

-- Evalúa un prompt. Con p_scenario_id usa la rúbrica del grupo de edad de la
-- misión; sin él (modo libre) usa la del usuario.
create or replace function public.evaluate_prompt(p_text text, p_scenario_id uuid default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_norm     text := public.normalize_prompt(p_text);
  v_words    integer := coalesce(array_length(regexp_split_to_array(btrim(coalesce(p_text, '')), '\s+'), 1), 0);
  v_rubric   text;
  v_criteria jsonb := '[]'::jsonb;
  v_penalties jsonb := '[]'::jsonb;
  v_total    numeric := 0;
  v_penalty  integer := 0;
  v_level    text;
  v_points   numeric;
  v_score    integer;
  v_message  text;
  c          record;
  p          record;
begin
  if char_length(coalesce(p_text, '')) > 4000 then
    raise exception 'El prompt es demasiado largo (máximo 4000 caracteres)' using errcode = 'P0001';
  end if;
  if btrim(coalesce(p_text, '')) = '' then
    v_words := 0;
  end if;

  select coalesce(g.prompt_rubric, public.my_prompt_rubric()) into v_rubric
  from (select 1) x
  left join public.scenarios s on s.id = p_scenario_id
  left join public.age_groups g on g.id = s.age_group_id;

  for c in select * from public.prompt_criteria where rubric = v_rubric order by sort_order loop
    if c.criterion_key = 'eficiencia' then
      -- Longitud razonable: ni demasiado escueto ni con relleno.
      v_level := case
        when v_words between 15 and 120 then 'strong'
        when v_words between 8 and 200 then 'partial'
        else 'missing' end;
    elsif exists (select 1 from public.prompt_rules r
                  where r.criterion_key = c.criterion_key and r.kind = 'strong' and v_norm ~ r.pattern) then
      v_level := 'strong';
    elsif exists (select 1 from public.prompt_rules r
                  where r.criterion_key = c.criterion_key and r.kind = 'partial' and v_norm ~ r.pattern) then
      v_level := 'partial';
    else
      v_level := 'missing';
    end if;

    v_points := case v_level when 'strong' then c.weight when 'partial' then c.weight / 2.0 else 0 end;
    v_total := v_total + v_points;
    v_criteria := v_criteria || jsonb_build_object(
      'key', c.criterion_key,
      'label', c.label,
      'description', c.description,
      'weight', c.weight,
      'points', round(v_points),
      'level', v_level,
      'feedback', case v_level when 'strong' then c.feedback_strong
                               when 'partial' then c.feedback_partial
                               else c.feedback_missing end
    );
  end loop;

  for p in select * from public.prompt_penalties where v_norm ~ pattern order by points desc loop
    v_penalty := v_penalty + p.points;
    v_penalties := v_penalties || jsonb_build_object('label', p.label, 'points', p.points, 'tip', p.tip);
  end loop;
  v_penalty := least(v_penalty, 40);

  v_score := greatest(0, least(100, round(v_total) - v_penalty))::int;

  select t.response_text into v_message
  from public.scenario_response_templates t
  where t.scenario_id = p_scenario_id and v_score between t.min_score and t.max_score
  limit 1;

  return jsonb_build_object(
    'score', v_score,
    'rubric', v_rubric,
    'words', v_words,
    'criteria', v_criteria,
    'penalties', v_penalties,
    'penalty', v_penalty,
    'message', coalesce(v_message, case
      when v_score >= 90 then '¡Excelente! Tu prompt es claro, completo y preciso.'
      when v_score >= 70 then '¡Buen prompt! Revisa los criterios incompletos para dejarlo perfecto.'
      when v_score >= 40 then 'Vas bien. Agrega los ingredientes que faltan para que la IA entienda mejor lo que necesitas.'
      else 'Tu prompt es muy general. Empieza por decir qué quieres (tarea), para qué (contexto) y cómo lo quieres (formato).'
    end)
  );
end;
$$;

-- Registra un intento de misión: califica en el servidor y guarda el resultado.
create or replace function public.submit_prompt_attempt(p_scenario_id uuid, p_text text)
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
  if char_length(btrim(coalesce(p_text, ''))) < 5 then
    raise exception 'Escribe tu prompt antes de enviarlo' using errcode = 'P0001';
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

  v_result := public.evaluate_prompt(p_text, p_scenario_id);
  v_passed := (v_result ->> 'score')::int >= v_scenario.passing_score;

  select coalesce(max(attempt_no), 0) + 1 into v_attempt
  from public.prompt_attempts where user_id = v_user and scenario_id = p_scenario_id;

  insert into public.prompt_attempts (user_id, scenario_id, score, attempt_no, prompt_text, passed)
  values (v_user, p_scenario_id, (v_result ->> 'score')::int, v_attempt, btrim(p_text), v_passed);

  return v_result || jsonb_build_object('attempt_no', v_attempt, 'passed', v_passed,
                                        'passing_score', v_scenario.passing_score);
end;
$$;

-- -----------------------------------------------------------------------------
-- complete_lesson(): las lecciones con misión exigen aprobarla
-- -----------------------------------------------------------------------------

create or replace function public.complete_lesson(p_lesson_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user    uuid := (select auth.uid());
  v_started timestamptz;
  v_pending integer;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;
  if not coalesce(public.lesson_is_unlocked(p_lesson_id), false) then
    raise exception 'Esta lección aún está bloqueada' using errcode = '42501';
  end if;

  select started_at into v_started
  from public.lesson_progress
  where user_id = v_user and lesson_id = p_lesson_id;

  if not public.is_staff() then
    if v_started is null or now() - v_started < make_interval(secs => public.min_lesson_seconds()) then
      raise exception 'Lee la lección al menos % segundos antes de completarla', public.min_lesson_seconds()
        using errcode = 'P0001';
    end if;

    select count(*) into v_pending
    from public.lesson_activities a
    left join public.activity_progress ap on ap.activity_id = a.id and ap.user_id = v_user
    where a.lesson_id = p_lesson_id and ap.completed_at is null;
    if v_pending > 0 then
      raise exception 'Primero termina el juego de esta lección' using errcode = 'P0001';
    end if;

    select count(*) into v_pending
    from public.flashcards f
    left join public.flashcard_reviews fr on fr.card_id = f.id and fr.user_id = v_user
    where f.lesson_id = p_lesson_id and fr.seen_at is null;
    if v_pending > 0 then
      raise exception 'Primero voltea las flashcards de esta lección' using errcode = 'P0001';
    end if;

    select count(*) into v_pending
    from public.articles ar
    left join public.article_progress ap on ap.article_id = ar.id and ap.user_id = v_user
    where ar.lesson_id = p_lesson_id and ar.is_public and ap.completed_at is null;
    if v_pending > 0 then
      raise exception 'Primero lee el artículo de esta lección' using errcode = 'P0001';
    end if;

    select count(*) into v_pending
    from public.scenarios s
    where s.lesson_id = p_lesson_id and s.is_published
      and not exists (select 1 from public.prompt_attempts pa
                      where pa.scenario_id = s.id and pa.user_id = v_user and pa.passed);
    if v_pending > 0 then
      raise exception 'Primero aprueba la misión del evaluador de prompts' using errcode = 'P0001';
    end if;
  end if;

  insert into public.lesson_progress (user_id, lesson_id, status, started_at, completed_at, last_activity_at)
  values (v_user, p_lesson_id, 'completed', now(), now(), now())
  on conflict (user_id, lesson_id) do update
    set status = 'completed',
        completed_at = coalesce(public.lesson_progress.completed_at, now()),
        last_activity_at = now();
end;
$$;

-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------

revoke execute on function
  public.normalize_prompt(text), public.my_prompt_rubric(),
  public.evaluate_prompt(text, uuid), public.submit_prompt_attempt(uuid, text),
  public.check_prompt_pattern()
  from public, anon;
grant execute on function
  public.normalize_prompt(text), public.my_prompt_rubric(),
  public.evaluate_prompt(text, uuid), public.submit_prompt_attempt(uuid, text)
  to authenticated;

-- -----------------------------------------------------------------------------
-- Rúbricas
-- -----------------------------------------------------------------------------

insert into public.prompt_criteria
  (rubric, criterion_key, label, description, weight, sort_order, feedback_strong, feedback_partial, feedback_missing)
select r.rubric, c.key, c.label, c.description,
       case when r.rubric = 'basica' then 20 else 14 end, c.ord,
       c.fs, c.fp, c.fm
from (values ('basica'), ('avanzada')) r(rubric)
cross join (values
  ('rol', 'Rol', 'Desde qué papel debe responder la IA.', 1,
   'Le das un rol claro a la IA.',
   'Mencionas a un experto, pero dilo como rol: «Actúa como…».',
   'Dile desde qué papel responder: «Actúa como un profesor de historia de secundaria».'),
  ('contexto', 'Contexto', 'Para qué lo necesitas y para quién es.', 2,
   'Explicas para qué y para quién es: la IA puede ajustar su respuesta.',
   'Mencionas el tema o la tarea; agrega para qué lo necesitas o tu nivel escolar.',
   'Cuenta la situación: «Estoy preparando una exposición para mis compañeros de 13 años».'),
  ('tarea', 'Tarea', 'Qué debe hacer la IA, con un verbo de acción.', 3,
   'Pides algo concreto con un verbo de acción.',
   'Se entiende que quieres algo, pero usa un verbo claro: explica, resume, compara, enumera…',
   'Di exactamente qué quieres que haga: «Explica las tres causas principales de…».'),
  ('formato', 'Formato', 'Cómo quieres recibir la respuesta.', 4,
   'Indicas cómo quieres la respuesta (estructura o extensión).',
   'Das una pista del formato; precisa la estructura o la extensión: «en una tabla de 3 columnas», «en 5 puntos».',
   'Indica cómo quieres la respuesta: tabla, lista, pasos, número de palabras…'),
  ('ejemplo', 'Ejemplo', 'Una muestra del estilo o resultado que esperas.', 5,
   'Incluyes un ejemplo que guía el estilo de la respuesta.',
   'Mencionas un ejemplo; escríbelo para que la IA lo imite: «Sigue este estilo: …».',
   'Agrega una muestra breve de lo que esperas: «Por ejemplo: Causa: … Personaje: …».')
) c(key, label, description, ord, fs, fp, fm);

insert into public.prompt_criteria
  (rubric, criterion_key, label, description, weight, sort_order, feedback_strong, feedback_partial, feedback_missing)
values
  ('avanzada', 'eficiencia', 'Eficiencia', 'Instrucciones completas sin relleno (15 a 120 palabras).', 15, 6,
   'Tu prompt tiene una extensión eficiente: completo y sin relleno.',
   'Ajusta la extensión: muy corto deja dudas y muy largo gasta tokens. Busca entre 15 y 120 palabras.',
   'Tu prompt es demasiado corto o demasiado largo. Busca entre 15 y 120 palabras con lo esencial.'),
  ('avanzada', 'tecnicas', 'Técnicas avanzadas', 'Ejemplos de entrada/salida, paso a paso, restricciones o preguntas de clarificación.', 15, 7,
   'Usas técnicas avanzadas que aumentan la precisión de la respuesta.',
   'Hay una restricción o una pista de técnica; prueba «razona paso a paso» o «antes de responder, hazme 3 preguntas».',
   'Usa una técnica de la lección 7.1: ejemplos (few-shot), «razona paso a paso», restricciones («no inventes datos») o pide que te haga preguntas primero.');

-- -----------------------------------------------------------------------------
-- Reglas (texto normalizado: minúsculas y sin acentos; \y = límite de palabra)
-- -----------------------------------------------------------------------------

insert into public.prompt_rules (criterion_key, kind, pattern) values
  -- Rol
  ('rol', 'strong', '\y(actua|actuar|actue|actues) como\y'),
  ('rol', 'strong', '\yeres (un|una|el|la) \w+'),
  ('rol', 'strong', '\y(imagina|supon|finge) que eres\y'),
  ('rol', 'strong', '\yasume el (rol|papel) de\y'),
  ('rol', 'strong', '\ytu (rol|papel) (es|sera) (el de )?\w+'),
  ('rol', 'strong', '\ycomo si fueras (un|una)\y'),
  ('rol', 'partial', '\y(experto|experta|profesor|profesora|maestro|maestra|tutor|tutora|especialista|cientifico|cientifica|historiador|historiadora|asesor|asesora|consultor|consultora|editor|editora|entrenador|entrenadora)\y'),

  -- Contexto
  ('contexto', 'strong', '\y(soy|somos) (un |una )?(estudiante|alumno|alumna|nino|nina|maestro|maestra|profesor|profesora)s?\y'),
  ('contexto', 'strong', '\y(estoy|voy|ando|estudio) en (\d+|primero|segundo|tercero|cuarto|quinto|sexto) (de )?(primaria|secundaria|prepa|preparatoria|bachillerato|semestre|grado|ano)\y'),
  ('contexto', 'strong', '\y(estoy|voy|estudio) en (la )?(primaria|secundaria|prepa|preparatoria|bachillerato|universidad)\y'),
  ('contexto', 'strong', '\ytengo \d+ anos\y'),
  ('contexto', 'strong', '\y(es|lo necesito|la necesito|lo quiero|lo voy a usar) para (una|un|mi|mis|la|el) \w+'),
  ('contexto', 'strong', '\ypara (mis companeros|mi clase|mi grupo|mi maestr[oa]|mi profesor[a]?|ninos|estudiantes|alumnos|personas que)\y'),
  ('contexto', 'strong', '\y(estoy preparando|estoy estudiando|estamos viendo|estoy haciendo|tengo que (presentar|entregar|exponer|estudiar)|me cuesta|no entiendo|ya lei|ya intente|mi objetivo es)\y'),
  ('contexto', 'partial', '\y(tarea|clase|examen|escuela|proyecto|materia|tema|exposicion|presentacion|ensayo|investigacion|trabajo|curso)\y'),

  -- Tarea
  ('tarea', 'strong', '\y(explica|explicame|explicar|resume|resumeme|resumir|compara|comparar|describe|describir|enumera|enumerar|lista|enlista|analiza|analizar|identifica|identificar|clasifica|clasificar|define|definir|genera|generar|crea|crear|propon|proponer|sugiere|sugerir|redacta|redactar|revisa|revisar|corrige|corregir|traduce|traducir|ordena|ordenar|calcula|calcular|elabora|elaborar|organiza|organizar|evalua|evaluar|menciona|mencionar|senala|senalar|disena|disenar|planea|planear|guiame|orientame)\y'),
  ('tarea', 'strong', '\y(hazme|dame|escribe|escribeme|formula|plantea) (\d+|una|un|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez) (preguntas|ejemplos|ideas|opciones|ejercicios|pistas|consejos|pasos|puntos)\y'),
  ('tarea', 'strong', '\yayudame a (entender|organizar|practicar|repasar|estudiar|preparar|planear|mejorar)\y'),
  ('tarea', 'partial', '\y(ayuda|ayudame|necesito|quiero|puedes|podrias|dime|hazme|dame|quisiera|me gustaria)\y'),

  -- Formato
  ('formato', 'strong', '\y(en|con|como) (una |un |forma de )?(tabla|lista|esquema|mapa (mental|conceptual)|cuadro (comparativo|sinoptico)?|linea del tiempo|vinetas|bullets|diagrama|guion|correo|carta)\y'),
  ('formato', 'strong', '\y(en|con|de) (\d+|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez) (puntos|pasos|parrafos|lineas|ideas|columnas|filas|oraciones|preguntas|ejemplos|secciones|partes|incisos|frases)\y'),
  ('formato', 'strong', '\y(maximo|minimo|no mas de|menos de|alrededor de|aproximadamente|hasta) \d+ (palabras|lineas|parrafos|caracteres|puntos|minutos|oraciones)\y'),
  ('formato', 'strong', '\ypaso a paso\y'),
  ('formato', 'strong', '\y(columnas|encabezados|titulos|subtitulos):'),
  ('formato', 'strong', '\y(usa|usando|con) (un )?lenguaje (sencillo|claro|formal|simple|facil|tecnico|para ninos)\y'),
  ('formato', 'partial', '\y(tabla|lista|esquema|breve|corto|corta|resumido|resumida|pasos|puntos|vinetas|parrafo|parrafos|sencillo|ordenado)\y'),

  -- Ejemplo
  ('ejemplo', 'strong', '\y(por ejemplo|p\. ?ej\.?|ejemplo:|como este ejemplo|como en este ejemplo|sigue (este|el siguiente) (estilo|ejemplo|formato|modelo)|algo (asi|como):|de esta forma:|asi:)'),
  ('ejemplo', 'strong', '["“«][^"”»]{12,}["”»]'),
  ('ejemplo', 'strong', '\y(entrada|pregunta) ?\d?: .+ (salida|respuesta) ?\d?:'),
  ('ejemplo', 'partial', '\y(ejemplo|ejemplos|como modelo|similar a|parecido a|al estilo de)\y'),

  -- Técnicas avanzadas (solo rúbrica avanzada)
  ('tecnicas', 'strong', '\y(razona|piensa|explica tu razonamiento|resuelvelo|analizalo) paso a paso\y'),
  ('tecnicas', 'strong', '\y(antes de (responder|empezar|redactar|comenzar)|primero),? (hazme|formulame|preguntame) (\d+ |unas |algunas |tres |cinco )?preguntas\y'),
  ('tecnicas', 'strong', '\yno (inventes|incluyas|uses|excedas|des la respuesta|me des la respuesta|resuelvas|escribas)\y'),
  ('tecnicas', 'strong', '\ysi no (sabes|estas seguro|tienes (el dato|la informacion)),? (dilo|indicalo|avisame|dimelo)\y'),
  ('tecnicas', 'strong', '\y(ejemplo 1|entrada:|salida:)'),
  ('tecnicas', 'strong', '\ycita (tus |las )?fuentes\y'),
  ('tecnicas', 'partial', '\y(evita|sin usar|limita|limitate|solo con|unicamente con|verifica|fuentes|razonamiento|restriccion|restricciones)\y');

-- -----------------------------------------------------------------------------
-- Penalizaciones por delegar el trabajo
-- -----------------------------------------------------------------------------

insert into public.prompt_penalties (label, pattern, points, tip) values
  ('Pedir que la IA haga tu tarea',
   '\y(hazme|haz|resuelve|resuelveme|contesta|contestame|realiza) (toda |todo )?(la |el |mi |mis )?(tarea|actividad|ejercicios?|examen|cuestionario|guia)\y',
   25, 'Pide ayuda para un paso: una explicación, una pista o preguntas para practicar, y haz tú la tarea.'),
  ('Pedir que la IA escriba tu trabajo',
   '\y(escribeme|redactame|hazme|elaborame) (todo |completo )?(el |mi |un |una )?(ensayo|trabajo|reporte|informe|monografia|tesis|resumen para entregar)\y',
   25, 'Escribe tú el borrador y pide a la IA que lo revise o te dé ideas para mejorarlo.'),
  ('Pedir solo las respuestas',
   '\y(dame|pon|escribe|pasame) (solo|unicamente|nada mas) (las )?respuestas\y',
   20, 'En vez de las respuestas, pide que te explique cómo llegar a ellas.'),
  ('Querer hacerlo pasar como tuyo',
   '\y(como si (lo hubiera hecho|fuera) yo|para entregarlo|que no se note que (es|fue|lo hizo) (una )?(ia|inteligencia artificial))\y',
   30, 'Usa la IA como apoyo y menciona cómo la usaste; entregar su trabajo como propio es plagio.');
