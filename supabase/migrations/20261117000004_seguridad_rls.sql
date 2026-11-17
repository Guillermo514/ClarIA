-- =============================================================================
-- ClarIA 2.0 · Migración 4: seguridad (RLS y permisos)
--
-- Reglas generales:
--  * Todas las tablas tienen RLS activado.
--  * El contenido publicado (niveles, lecciones, artículos, flashcards, preguntas)
--    es de lectura pública; solo los administradores lo modifican.
--  * Los datos de cada estudiante (progreso, intentos, repasos, logros) solo los
--    ve y modifica su dueño.
--  * Las respuestas correctas (question_options.is_correct / correct_order) no se
--    exponen: la calificación ocurre en public.submit_quiz().
--  * Los intentos de evaluación y las medallas solo se crean desde funciones del
--    servidor, nunca directamente desde el navegador.
-- =============================================================================

do $$
declare
  t text;
begin
  for t in select tablename from pg_tables where schemaname = 'public' loop
    execute format('alter table public.%I enable row level security', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Catálogos de lectura pública
-- -----------------------------------------------------------------------------

create policy "Catálogo visible para todos" on public.roles
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.age_groups
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.privacy_notice_versions
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.achievements
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.sources
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.eco_task_types
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.eco_factor_versions
  for select to anon, authenticated using (true);
create policy "Catálogo visible para todos" on public.eco_factor_sources
  for select to anon, authenticated using (true);

-- -----------------------------------------------------------------------------
-- Contenido publicado
-- -----------------------------------------------------------------------------

create policy "Niveles publicados" on public.courses
  for select to anon, authenticated
  using ((is_published and deleted_at is null) or (select public.is_admin()));

create policy "Lecciones de niveles publicados" on public.lessons
  for select to anon, authenticated
  using ((deleted_at is null and public.course_is_visible(course_id)) or (select public.is_admin()));

create policy "Juegos de lecciones visibles" on public.lesson_activities
  for select to anon, authenticated using (public.lesson_is_visible(lesson_id));

create policy "Artículos públicos de lecciones visibles" on public.articles
  for select to anon, authenticated
  using ((is_public and public.lesson_is_visible(lesson_id)) or (select public.is_admin()));

create policy "Fuentes de artículos visibles" on public.article_sources
  for select to anon, authenticated using (true);

create policy "Flashcards de lecciones visibles" on public.flashcards
  for select to anon, authenticated using (public.lesson_is_visible(lesson_id));

create policy "Evaluaciones publicadas" on public.quizzes
  for select to anon, authenticated
  using (public.quiz_is_visible(id) or (select public.is_admin()));

create policy "Preguntas de evaluaciones visibles" on public.questions
  for select to anon, authenticated using (public.quiz_is_visible(quiz_id));

create policy "Opciones de preguntas visibles" on public.question_options
  for select to anon, authenticated using (public.question_is_visible(question_id));

create policy "Ejercicios de lecciones visibles" on public.critical_exercises
  for select to anon, authenticated using (public.lesson_is_visible(lesson_id));
create policy "Problemas de ejercicios visibles" on public.critical_exercise_issues
  for select to anon, authenticated using (true);

create policy "Escenarios publicados" on public.scenarios
  for select to anon, authenticated using (is_published or (select public.is_admin()));
create policy "Criterios de escenarios publicados" on public.scenario_criteria
  for select to anon, authenticated
  using (exists (select 1 from public.scenarios s where s.id = scenario_id and s.is_published));
create policy "Plantillas de escenarios publicados" on public.scenario_response_templates
  for select to anon, authenticated
  using (exists (select 1 from public.scenarios s where s.id = scenario_id and s.is_published));

create policy "Encuestas publicadas" on public.surveys
  for select to anon, authenticated using (is_published or (select public.is_admin()));
create policy "Preguntas de encuestas publicadas" on public.survey_questions
  for select to anon, authenticated
  using (exists (select 1 from public.surveys s where s.id = survey_id and s.is_published));
create policy "Opciones de encuestas publicadas" on public.survey_options
  for select to anon, authenticated
  using (exists (select 1 from public.survey_questions q
                 join public.surveys s on s.id = q.survey_id
                 where q.id = question_id and s.is_published));

create policy "Reglas de logros visibles" on public.achievement_rule_groups
  for select to anon, authenticated using (true);
create policy "Reglas de logros visibles" on public.achievement_rules
  for select to anon, authenticated using (true);

-- Administración del contenido (solo admin).
do $$
declare
  t text;
begin
  foreach t in array array[
    'age_groups', 'courses', 'lessons', 'lesson_activities', 'sources', 'articles', 'article_sources',
    'quizzes', 'questions', 'question_options', 'flashcards', 'critical_exercises',
    'critical_exercise_issues', 'scenarios', 'scenario_criteria', 'scenario_response_templates',
    'surveys', 'survey_questions', 'survey_options', 'achievements', 'achievement_rule_groups',
    'achievement_rules', 'eco_task_types', 'eco_factor_versions', 'eco_factor_sources',
    'privacy_notice_versions']
  loop
    execute format(
      'create policy "Administración del contenido" on public.%I
         for all to authenticated
         using ((select public.is_admin())) with check ((select public.is_admin()))', t);
  end loop;
end;
$$;

-- -----------------------------------------------------------------------------
-- Datos de cada usuario
-- -----------------------------------------------------------------------------

create policy "Ver mi perfil" on public.profiles
  for select to authenticated
  using (id = (select auth.uid()) or (select public.current_role_name()) in ('teacher', 'admin'));
create policy "Editar mi perfil" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

create policy "Ver mis consentimientos" on public.privacy_consents
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Aceptar un aviso de privacidad" on public.privacy_consents
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy "Ver mi progreso" on public.lesson_progress
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Registrar mi progreso" on public.lesson_progress
  for insert to authenticated
  with check (user_id = (select auth.uid()) and public.lesson_is_unlocked(lesson_id));
create policy "Actualizar mi progreso" on public.lesson_progress
  for update to authenticated
  using (user_id = (select auth.uid()))
  with check (user_id = (select auth.uid()) and public.lesson_is_unlocked(lesson_id));

create policy "Ver mis intentos" on public.quiz_attempts
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Ver mis respuestas" on public.quiz_answers
  for select to authenticated
  using (exists (select 1 from public.quiz_attempts a
                 where a.id = attempt_id and a.user_id = (select auth.uid())));
create policy "Ver mis opciones elegidas" on public.quiz_answer_options
  for select to authenticated
  using (exists (select 1 from public.quiz_answers qa
                 join public.quiz_attempts a on a.id = qa.attempt_id
                 where qa.id = answer_id and a.user_id = (select auth.uid())));

create policy "Mis repasos de flashcards" on public.flashcard_reviews
  for all to authenticated
  using (user_id = (select auth.uid())) with check (user_id = (select auth.uid()));

create policy "Ver mis medallas" on public.user_achievements
  for select to authenticated using (user_id = (select auth.uid()));

create policy "Mis intentos de ejercicios" on public.exercise_attempts
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Registrar intento de ejercicio" on public.exercise_attempts
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Mis problemas seleccionados" on public.selected_exercise_issues
  for select to authenticated
  using (exists (select 1 from public.exercise_attempts a
                 where a.id = attempt_id and a.user_id = (select auth.uid())));
create policy "Registrar problemas seleccionados" on public.selected_exercise_issues
  for insert to authenticated
  with check (exists (select 1 from public.exercise_attempts a
                      where a.id = attempt_id and a.user_id = (select auth.uid())));

create policy "Mis intentos de prompts" on public.prompt_attempts
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Registrar intento de prompt" on public.prompt_attempts
  for insert to authenticated with check (user_id = (select auth.uid()));

create policy "Mis respuestas de encuestas" on public.survey_responses
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Responder encuesta" on public.survey_responses
  for insert to authenticated with check (user_id = (select auth.uid()));
create policy "Mis respuestas por pregunta" on public.survey_answers
  for select to authenticated
  using (exists (select 1 from public.survey_responses r
                 where r.id = response_id and r.user_id = (select auth.uid())));
create policy "Registrar respuesta por pregunta" on public.survey_answers
  for insert to authenticated
  with check (exists (select 1 from public.survey_responses r
                      where r.id = response_id and r.user_id = (select auth.uid())));
create policy "Mis opciones de encuesta" on public.survey_answer_options
  for select to authenticated
  using (exists (select 1 from public.survey_answers sa
                 join public.survey_responses r on r.id = sa.response_id
                 where sa.id = answer_id and r.user_id = (select auth.uid())));
create policy "Registrar opciones de encuesta" on public.survey_answer_options
  for insert to authenticated
  with check (exists (select 1 from public.survey_answers sa
                      join public.survey_responses r on r.id = sa.response_id
                      where sa.id = answer_id and r.user_id = (select auth.uid())));

create policy "Mis estimaciones ambientales" on public.eco_estimates
  for select to authenticated using (user_id = (select auth.uid()));
create policy "Registrar estimación ambiental" on public.eco_estimates
  for insert to authenticated with check (user_id = (select auth.uid()));

-- Auditoría: solo administradores (se escribe desde triggers).
create policy "Auditoría solo admin" on public.audit_entity_types
  for select to authenticated using ((select public.is_admin()));
create policy "Auditoría solo admin" on public.audit_logs
  for select to authenticated using ((select public.is_admin()));
create policy "Auditoría solo admin" on public.audit_log_changes
  for select to authenticated using ((select public.is_admin()));

-- -----------------------------------------------------------------------------
-- Permisos por columna
-- -----------------------------------------------------------------------------

-- Las respuestas correctas nunca salen hacia el navegador.
revoke select on public.question_options from anon, authenticated;
grant select (id, question_id, option_text, sort_order) on public.question_options to anon, authenticated;

-- El estudiante solo puede editar estos datos de su perfil (no su rol ni su estado).
revoke insert, update, delete on public.profiles from anon, authenticated;
grant update (full_name, institution, academic_level) on public.profiles to authenticated;

-- Intentos y medallas solo se crean desde submit_quiz().
revoke insert, update, delete on public.quiz_attempts, public.quiz_answers,
  public.quiz_answer_options, public.user_achievements from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Permisos de funciones
-- -----------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon, authenticated;

-- Usadas por las políticas RLS: deben poder ejecutarse por quien consulta.
grant execute on function
  public.current_role_name(), public.is_admin(), public.my_age_group_id(),
  public.course_is_visible(uuid), public.lesson_is_visible(uuid),
  public.quiz_is_visible(uuid), public.question_is_visible(uuid),
  public.course_is_unlocked(uuid), public.lesson_is_unlocked(uuid)
  to anon, authenticated;

-- API para la aplicación.
grant execute on function
  public.get_my_levels(), public.submit_quiz(uuid, jsonb), public.load_curriculum(jsonb)
  to authenticated;

-- Las funciones nuevas no quedan ejecutables por defecto.
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;
