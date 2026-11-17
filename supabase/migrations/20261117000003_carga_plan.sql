-- =============================================================================
-- ClarIA 2.0 · Migración 3: carga del Plan Curricular
-- Función idempotente que inserta/actualiza niveles, lecciones, juegos, artículos,
-- fuentes, flashcards, evaluaciones y medallas, y el aviso de privacidad vigente.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- Carga del Plan Curricular
-- -----------------------------------------------------------------------------

-- Inserta o actualiza todo el contenido a partir del JSON generado por
-- scripts/plan_curricular_a_json.py (supabase/seed/plan-curricular.json).
-- Es idempotente: se puede volver a ejecutar cuando cambie el plan.
create or replace function public._load_curriculum(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_group    jsonb;
  v_level    jsonb;
  v_lesson   jsonb;
  v_question jsonb;
  v_course   uuid;
  v_lesson_id uuid;
  v_source   uuid;
  v_article  uuid;
  v_quiz     uuid;
  v_q_id     uuid;
  v_i        integer;
  v_url      text;
  v_card     jsonb;
  v_option   jsonb;
  v_counts   jsonb;
begin
  perform set_config('claria.skip_audit', 'on', true);

  for v_group in select * from jsonb_array_elements(p_payload -> 'age_groups') loop
    insert into public.age_groups (code, name, min_age, max_age, sort_order)
    values (v_group ->> 'code', v_group ->> 'name', (v_group ->> 'min_age')::smallint,
            (v_group ->> 'max_age')::smallint, (v_group ->> 'sort_order')::smallint)
    on conflict (code) do update
      set name = excluded.name, min_age = excluded.min_age,
          max_age = excluded.max_age, sort_order = excluded.sort_order;
  end loop;

  for v_level in select * from jsonb_array_elements(p_payload -> 'levels') loop
    insert into public.courses (age_group_id, level_number, title, objective, sort_order, is_published)
    values ((select id from public.age_groups where code = v_level ->> 'age_group'),
            (v_level ->> 'number')::smallint, v_level ->> 'title', v_level ->> 'objective',
            (v_level ->> 'sort_order')::smallint, true)
    on conflict (level_number) do update
      set age_group_id = excluded.age_group_id, title = excluded.title,
          objective = excluded.objective, sort_order = excluded.sort_order
    returning id into v_course;

    for v_lesson in select * from jsonb_array_elements(v_level -> 'lessons') loop
      insert into public.lessons (course_id, code, title, content, sort_order, duration_min, type)
      values (v_course, v_lesson ->> 'code', v_lesson ->> 'title', v_lesson ->> 'content',
              (v_lesson ->> 'sort_order')::smallint, (v_lesson ->> 'duration_min')::smallint,
              case when jsonb_array_length(v_lesson -> 'games') > 0 then 'practice' else 'reading' end)
      on conflict (code) do update
        set course_id = excluded.course_id, title = excluded.title, content = excluded.content,
            sort_order = excluded.sort_order, duration_min = excluded.duration_min, type = excluded.type
      returning id into v_lesson_id;

      -- Juegos
      delete from public.lesson_activities where lesson_id = v_lesson_id;
      v_i := 0;
      for v_url in select jsonb_array_elements_text(v_lesson -> 'games') loop
        v_i := v_i + 1;
        insert into public.lesson_activities (lesson_id, title, embed_url, sort_order)
        values (v_lesson_id, 'Dinámica: ' || (v_lesson ->> 'title'), v_url, v_i);
      end loop;

      -- Fuente confiable y artículo
      insert into public.sources (citation, url)
      values (v_lesson -> 'source' ->> 'citation', v_lesson -> 'source' ->> 'url')
      on conflict (url) do update set citation = excluded.citation
      returning id into v_source;

      insert into public.articles (lesson_id, title, summary, body, author, published_label)
      values (v_lesson_id, v_lesson -> 'article' ->> 'title', v_lesson -> 'article' ->> 'summary',
              v_lesson -> 'article' ->> 'body', v_lesson -> 'article' ->> 'author',
              v_lesson -> 'article' ->> 'published_label')
      on conflict (lesson_id, title) do update
        set summary = excluded.summary, body = excluded.body, author = excluded.author,
            published_label = excluded.published_label
      returning id into v_article;

      insert into public.article_sources (article_id, source_id)
      values (v_article, v_source)
      on conflict do nothing;

      -- Flashcards
      v_i := 0;
      for v_card in select * from jsonb_array_elements(v_lesson -> 'flashcards') loop
        v_i := v_i + 1;
        insert into public.flashcards (lesson_id, front, back, sort_order)
        values (v_lesson_id, v_card ->> 'front', v_card ->> 'back', v_i)
        on conflict (lesson_id, sort_order) do update
          set front = excluded.front, back = excluded.back;
      end loop;
    end loop;

    -- Evaluación final del nivel
    insert into public.quizzes (course_id, title, passing_score, is_published)
    values (v_course, v_level -> 'quiz' ->> 'title', (v_level -> 'quiz' ->> 'passing_score')::numeric, true)
    on conflict (course_id) where course_id is not null do update
      set title = excluded.title, passing_score = excluded.passing_score
    returning id into v_quiz;

    v_i := 0;
    for v_question in select * from jsonb_array_elements(v_level -> 'quiz' -> 'questions') loop
      v_i := v_i + 1;
      if (select count(*) from jsonb_array_elements(v_question -> 'options') o
          where (o ->> 'is_correct')::boolean) <> 1 then
        raise exception 'Nivel %, pregunta %: debe tener exactamente una respuesta correcta',
          v_level ->> 'number', v_i;
      end if;

      insert into public.questions (quiz_id, statement, type, sort_order)
      values (v_quiz, v_question ->> 'statement', 'single_choice', v_i)
      on conflict (quiz_id, sort_order) do update set statement = excluded.statement
      returning id into v_q_id;

      for v_option in
        select value || jsonb_build_object('n', ordinality)
        from jsonb_array_elements(v_question -> 'options') with ordinality
      loop
        insert into public.question_options (question_id, option_text, is_correct, sort_order)
        values (v_q_id, v_option ->> 'text', (v_option ->> 'is_correct')::boolean, (v_option ->> 'n')::smallint)
        on conflict (question_id, sort_order) do update
          set option_text = excluded.option_text, is_correct = excluded.is_correct;
      end loop;
    end loop;

    -- Medalla del nivel
    insert into public.achievements (name, description, icon, course_id, sort_order)
    values (v_level -> 'medal' ->> 'name', v_level -> 'medal' ->> 'description',
            v_level -> 'medal' ->> 'icon', v_course, (v_level ->> 'number')::smallint)
    on conflict (name) do update
      set description = excluded.description, icon = excluded.icon,
          course_id = excluded.course_id, sort_order = excluded.sort_order;
  end loop;

  select jsonb_build_object(
    'age_groups', (select count(*) from public.age_groups),
    'courses', (select count(*) from public.courses),
    'lessons', (select count(*) from public.lessons),
    'lesson_activities', (select count(*) from public.lesson_activities),
    'articles', (select count(*) from public.articles),
    'sources', (select count(*) from public.sources),
    'flashcards', (select count(*) from public.flashcards),
    'quizzes', (select count(*) from public.quizzes),
    'questions', (select count(*) from public.questions),
    'question_options', (select count(*) from public.question_options),
    'achievements', (select count(*) from public.achievements)
  ) into v_counts;

  return v_counts;
end;
$$;

-- Punto de entrada público: solo administradores.
create or replace function public.load_curriculum(p_payload jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
begin
  if not public.is_admin() then
    raise exception 'Solo un administrador puede cargar el Plan Curricular' using errcode = '42501';
  end if;
  return public._load_curriculum(p_payload);
end;
$$;

-- Aviso de privacidad vigente (el texto vive en el frontend, ruta /aviso-de-privacidad).
insert into public.privacy_notice_versions (version, content_reference)
values ('1.0', '/aviso-de-privacidad');
