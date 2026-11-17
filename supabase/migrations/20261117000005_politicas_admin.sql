-- =============================================================================
-- ClarIA 2.0 · Migración 5: políticas de administración sin duplicar lecturas
-- La política "for all" de administración se evaluaba junto con la de lectura en
-- cada SELECT (aviso multiple_permissive_policies). Se separa en insert, update y
-- delete; la lectura del admin ya está cubierta por las políticas de lectura.
-- =============================================================================

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
    execute format('drop policy "Administración del contenido" on public.%I', t);
    execute format(
      'create policy "Admin crea contenido" on public.%I
         for insert to authenticated with check ((select public.is_admin()))', t);
    execute format(
      'create policy "Admin edita contenido" on public.%I
         for update to authenticated
         using ((select public.is_admin())) with check ((select public.is_admin()))', t);
    execute format(
      'create policy "Admin elimina contenido" on public.%I
         for delete to authenticated using ((select public.is_admin()))', t);
  end loop;
end;
$$;
