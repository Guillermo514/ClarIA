-- =============================================================================
-- ClarIA 2.0 · Migración 2: funciones y triggers
-- Registro de usuarios, grupo de edad, desbloqueo de niveles, calificación de
-- evaluaciones en el servidor, auditoría y carga del Plan Curricular.
-- Todas las funciones SECURITY DEFINER fijan search_path = '' por seguridad.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Usuario actual
-- -----------------------------------------------------------------------------

-- Rol del usuario autenticado ('student', 'teacher', 'admin') o null.
create or replace function public.current_role_name()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select r.name
  from public.profiles p
  join public.roles r on r.id = p.role_id
  where p.id = (select auth.uid()) and p.is_active;
$$;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.current_role_name() = 'admin', false);
$$;

-- Grupo de edad del usuario según su fecha de nacimiento, calculado al momento:
-- así el estudiante pasa al siguiente grupo cuando cumple años.
create or replace function public.my_age_group_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  with me as (
    select date_part('year', age(current_date, p.birth_date))::int as age
    from public.profiles p
    where p.id = (select auth.uid())
  )
  select g.id
  from public.age_groups g, me
  order by (me.age between g.min_age and coalesce(g.max_age, 200)) desc,
           abs(g.min_age - me.age)
  limit 1;
$$;

-- -----------------------------------------------------------------------------
-- Visibilidad del contenido (usadas por las políticas RLS)
-- -----------------------------------------------------------------------------

create or replace function public.course_is_visible(p_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.courses c
    where c.id = p_course_id and c.is_published and c.deleted_at is null
  );
$$;

create or replace function public.lesson_is_visible(p_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.lessons l
    join public.courses c on c.id = l.course_id
    where l.id = p_lesson_id and l.deleted_at is null
      and c.is_published and c.deleted_at is null
  );
$$;

create or replace function public.quiz_is_visible(p_quiz_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.quizzes q
    where q.id = p_quiz_id and q.is_published
      and (public.course_is_visible(q.course_id) or public.lesson_is_visible(q.lesson_id))
  );
$$;

create or replace function public.question_is_visible(p_question_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.questions q
    where q.id = p_question_id and public.quiz_is_visible(q.quiz_id)
  );
$$;

-- -----------------------------------------------------------------------------
-- Avance por niveles
-- -----------------------------------------------------------------------------

-- Un nivel está desbloqueado si pertenece al grupo de edad del estudiante y es
-- el primero del grupo o ya aprobó la evaluación final del nivel anterior.
-- Docentes y administradores ven todos los niveles.
create or replace function public.course_is_unlocked(p_course_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role   text := public.current_role_name();
  v_course public.courses;
  v_prev   uuid;
begin
  if v_role is null then
    return false;
  end if;
  if v_role in ('admin', 'teacher') then
    return true;
  end if;

  select * into v_course
  from public.courses
  where id = p_course_id and is_published and deleted_at is null;
  if not found or v_course.age_group_id is distinct from public.my_age_group_id() then
    return false;
  end if;

  select id into v_prev
  from public.courses
  where age_group_id = v_course.age_group_id
    and sort_order < v_course.sort_order
    and is_published and deleted_at is null
  order by sort_order desc
  limit 1;

  if v_prev is null then
    return true;
  end if;

  return exists (
    select 1
    from public.quiz_attempts a
    join public.quizzes q on q.id = a.quiz_id
    where q.course_id = v_prev and a.user_id = (select auth.uid()) and a.passed
  );
end;
$$;

create or replace function public.lesson_is_unlocked(p_lesson_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.course_is_unlocked(l.course_id)
  from public.lessons l
  where l.id = p_lesson_id and l.deleted_at is null;
$$;

-- Niveles que ve el usuario (su grupo de edad, o todos si es docente/admin),
-- con su estado de desbloqueo, progreso y medalla.
create or replace function public.get_my_levels()
returns table (
  id                uuid,
  level_number      smallint,
  title             text,
  objective         text,
  age_group_code    text,
  age_group_name    text,
  unlocked          boolean,
  passed            boolean,
  best_score        numeric,
  lessons_total     integer,
  lessons_completed integer,
  medal_name        text,
  medal_icon        text,
  medal_earned      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    c.id,
    c.level_number,
    c.title,
    c.objective,
    g.code,
    g.name,
    public.course_is_unlocked(c.id),
    coalesce(bool_or(a.passed), false),
    max(a.score),
    (select count(*)::int from public.lessons l where l.course_id = c.id and l.deleted_at is null),
    (select count(*)::int
       from public.lesson_progress lp
       join public.lessons l on l.id = lp.lesson_id
      where l.course_id = c.id and lp.user_id = (select auth.uid()) and lp.status = 'completed'),
    ach.name,
    ach.icon,
    exists (select 1 from public.user_achievements ua
             where ua.achievement_id = ach.id and ua.user_id = (select auth.uid()))
  from public.courses c
  join public.age_groups g on g.id = c.age_group_id
  left join public.quizzes q on q.course_id = c.id
  left join public.quiz_attempts a on a.quiz_id = q.id and a.user_id = (select auth.uid())
  left join public.achievements ach on ach.course_id = c.id
  where (select auth.uid()) is not null
    and c.is_published and c.deleted_at is null
    and (public.current_role_name() in ('admin', 'teacher') or c.age_group_id = public.my_age_group_id())
  group by c.id, g.id, ach.id
  order by c.level_number;
$$;

-- -----------------------------------------------------------------------------
-- Calificación de evaluaciones (solo en el servidor)
-- -----------------------------------------------------------------------------

-- Recibe [{"question_id": uuid, "option_ids": [uuid, ...]}, ...], califica contra
-- las respuestas correctas (que el estudiante nunca puede leer), guarda el intento
-- y, si aprueba la evaluación final de un nivel, otorga su medalla.
create or replace function public.submit_quiz(p_quiz_id uuid, p_answers jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user      uuid := (select auth.uid());
  v_quiz      public.quizzes;
  v_course_id uuid;
  v_total     integer;
  v_correct   integer := 0;
  v_attempt   uuid;
  v_answer    uuid;
  v_question  record;
  v_selected  uuid[];
  v_expected  uuid[];
  v_ok        boolean;
  v_results   jsonb := '[]'::jsonb;
  v_score     numeric(5, 2);
  v_passed    boolean;
  v_medal     jsonb;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión para presentar la evaluación' using errcode = '28000';
  end if;
  if p_answers is null or jsonb_typeof(p_answers) <> 'array' then
    raise exception 'Formato de respuestas inválido' using errcode = '22023';
  end if;

  select * into v_quiz from public.quizzes where id = p_quiz_id and is_published;
  if not found then
    raise exception 'Evaluación no encontrada' using errcode = 'P0002';
  end if;

  v_course_id := coalesce(v_quiz.course_id,
                          (select l.course_id from public.lessons l where l.id = v_quiz.lesson_id));
  if not public.course_is_unlocked(v_course_id) then
    raise exception 'Este nivel aún está bloqueado' using errcode = '42501';
  end if;

  select count(*) into v_total from public.questions where quiz_id = p_quiz_id;
  if v_total = 0 then
    raise exception 'La evaluación no tiene preguntas' using errcode = 'P0002';
  end if;

  insert into public.quiz_attempts (user_id, quiz_id, score, passed)
  values (v_user, p_quiz_id, 0, false)
  returning id into v_attempt;

  for v_question in
    select id from public.questions where quiz_id = p_quiz_id order by sort_order
  loop
    -- Opciones elegidas que realmente pertenecen a la pregunta (se ignoran las ajenas).
    select coalesce(array_agg(o.id order by o.id), '{}')
      into v_selected
      from public.question_options o
     where o.question_id = v_question.id
       and o.id::text in (
         select jsonb_array_elements_text(coalesce(a -> 'option_ids', '[]'::jsonb))
         from jsonb_array_elements(p_answers) a
         where a ->> 'question_id' = v_question.id::text
       );

    select coalesce(array_agg(o.id order by o.id), '{}')
      into v_expected
      from public.question_options o
     where o.question_id = v_question.id and o.is_correct;

    v_ok := cardinality(v_selected) > 0 and v_selected = v_expected;
    if v_ok then
      v_correct := v_correct + 1;
    end if;

    insert into public.quiz_answers (attempt_id, question_id, score_earned)
    values (v_attempt, v_question.id, case when v_ok then 1 else 0 end)
    returning id into v_answer;

    insert into public.quiz_answer_options (answer_id, option_id)
    select v_answer, unnest(v_selected);

    v_results := v_results || jsonb_build_object(
      'question_id', v_question.id,
      'correct', v_ok,
      'correct_option_ids', to_jsonb(v_expected)
    );
  end loop;

  v_score := round(v_correct * 100.0 / v_total, 2);
  v_passed := v_score >= v_quiz.passing_score;

  update public.quiz_attempts
     set score = v_score, passed = v_passed, finished_at = now()
   where id = v_attempt;

  if v_passed and v_quiz.course_id is not null then
    with earned as (
      insert into public.user_achievements (user_id, achievement_id)
      select v_user, ach.id from public.achievements ach where ach.course_id = v_quiz.course_id
      on conflict do nothing
      returning achievement_id
    )
    select jsonb_build_object('name', ach.name, 'icon', ach.icon)
      into v_medal
      from earned join public.achievements ach on ach.id = earned.achievement_id;
  end if;

  return jsonb_build_object(
    'attempt_id', v_attempt,
    'score', v_score,
    'passed', v_passed,
    'correct', v_correct,
    'total', v_total,
    'passing_score', v_quiz.passing_score,
    'results', v_results,
    'new_medal', v_medal
  );
end;
$$;

-- -----------------------------------------------------------------------------
-- Registro: crea el perfil y guarda la aceptación del aviso de privacidad
-- -----------------------------------------------------------------------------

-- Los datos llegan en options.data de supabase.auth.signUp():
-- full_name, birth_date (AAAA-MM-DD), institution, academic_level, privacy_notice_version.
-- Las cuentas creadas desde el panel de Supabase sin estos datos (docentes/admin)
-- no reciben perfil automático; se les crea a mano (ver docs/base-de-datos.md).
create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_meta   jsonb := coalesce(new.raw_user_meta_data, '{}'::jsonb);
  v_birth  date;
  v_age    integer;
  v_notice uuid;
begin
  if v_meta ->> 'full_name' is null then
    return new;
  end if;

  begin
    v_birth := (v_meta ->> 'birth_date')::date;
  exception when others then
    raise exception 'La fecha de nacimiento no es válida';
  end;
  if v_birth is null then
    raise exception 'La fecha de nacimiento es obligatoria';
  end if;

  v_age := date_part('year', age(current_date, v_birth));
  if v_age < 8 or v_age > 120 then
    raise exception 'ClarIA está dirigida a personas de 8 años en adelante';
  end if;

  select id into v_notice
  from public.privacy_notice_versions
  where version = v_meta ->> 'privacy_notice_version';
  if v_notice is null then
    raise exception 'Debes aceptar el aviso de privacidad vigente';
  end if;

  insert into public.profiles (id, full_name, birth_date, institution, academic_level, role_id)
  values (
    new.id,
    btrim(v_meta ->> 'full_name'),
    v_birth,
    nullif(btrim(v_meta ->> 'institution'), ''),
    nullif(v_meta ->> 'academic_level', ''),
    (select id from public.roles where name = 'student')
  );

  insert into public.privacy_consents (user_id, notice_version_id)
  values (new.id, v_notice);

  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- Auditoría de cambios en el contenido
-- -----------------------------------------------------------------------------

create or replace function public.audit_content_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_log uuid;
begin
  -- La carga masiva del Plan Curricular no genera un registro por fila.
  if current_setting('claria.skip_audit', true) = 'on' then
    return coalesce(new, old);
  end if;

  insert into public.audit_logs (actor_id, entity_type_id, entity_id, action)
  values (
    (select p.id from public.profiles p where p.id = (select auth.uid())),
    (select t.id from public.audit_entity_types t where t.name = tg_table_name),
    (coalesce(v_new, v_old) ->> 'id')::uuid,
    tg_op
  )
  returning id into v_log;

  if tg_op = 'UPDATE' then
    insert into public.audit_log_changes (audit_log_id, field_name, old_value, new_value)
    select v_log, n.key, v_old ->> n.key, n.value #>> '{}'
    from jsonb_each(v_new) n
    where n.key <> 'updated_at' and n.value is distinct from v_old -> n.key;
  end if;

  return coalesce(new, old);
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['courses', 'lessons', 'lesson_activities', 'sources', 'articles',
                           'quizzes', 'questions', 'question_options', 'flashcards', 'achievements']
  loop
    execute format(
      'create trigger %I after insert or update or delete on public.%I
         for each row execute function public.audit_content_change()',
      t || '_audit', t);
  end loop;
end;
$$;
