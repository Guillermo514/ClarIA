-- =============================================================================
-- ClarIA 2.0 · Migración 1: esquema base
-- Tablas, restricciones de validación e índices. Sigue el diagrama ClariaDB
-- con las ampliaciones necesarias para el Plan Curricular (ver docs/base-de-datos.md).
-- =============================================================================

-- Mantiene updated_at al día en las tablas que lo tienen.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- -----------------------------------------------------------------------------
-- Usuarios, roles y privacidad
-- -----------------------------------------------------------------------------

create table public.roles (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique check (name in ('student', 'teacher', 'admin'))
);

-- Grupos de edad del Plan Curricular (8-11, 12-14, 15-17, 18+).
create table public.age_groups (
  id         uuid primary key default gen_random_uuid(),
  code       text not null unique check (code ~ '^[0-9]{1,2}(-[0-9]{1,2}|\+)$'),
  name       text not null check (char_length(btrim(name)) between 1 and 60),
  min_age    smallint not null check (min_age between 3 and 120),
  max_age    smallint check (max_age is null or max_age between min_age and 120),
  sort_order smallint not null unique check (sort_order > 0)
);

create table public.profiles (
  id             uuid primary key references auth.users (id) on delete cascade,
  full_name      text not null check (char_length(btrim(full_name)) between 2 and 100),
  birth_date     date not null check (birth_date > date '1900-01-01'),
  institution    text check (institution is null or char_length(btrim(institution)) between 2 and 150),
  academic_level text check (academic_level in ('primaria', 'secundaria', 'preparatoria', 'universidad', 'otro')),
  role_id        uuid not null references public.roles (id),
  is_active      boolean not null default true,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);
create index profiles_role_id_idx on public.profiles (role_id);
create trigger profiles_set_updated_at before update on public.profiles
  for each row execute function public.set_updated_at();

create table public.privacy_notice_versions (
  id                uuid primary key default gen_random_uuid(),
  version           text not null unique check (version ~ '^[0-9]+\.[0-9]+$'),
  content_reference text not null check (char_length(btrim(content_reference)) > 0),
  published_at      timestamptz not null default now()
);

create table public.privacy_consents (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  notice_version_id uuid not null references public.privacy_notice_versions (id),
  accepted_at       timestamptz not null default now(),
  unique (user_id, notice_version_id)
);
create index privacy_consents_notice_version_id_idx on public.privacy_consents (notice_version_id);

-- -----------------------------------------------------------------------------
-- Niveles (courses), lecciones, juegos y progreso
-- -----------------------------------------------------------------------------

-- Cada fila es un Nivel del Plan Curricular (1 a 12).
create table public.courses (
  id           uuid primary key default gen_random_uuid(),
  age_group_id uuid not null references public.age_groups (id),
  level_number smallint not null unique check (level_number between 1 and 99),
  title        text not null check (char_length(btrim(title)) between 1 and 200),
  objective    text not null check (char_length(btrim(objective)) between 1 and 600),
  sort_order   smallint not null check (sort_order > 0),
  is_published boolean not null default false,
  deleted_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (age_group_id, sort_order)
);
create trigger courses_set_updated_at before update on public.courses
  for each row execute function public.set_updated_at();

create table public.lessons (
  id           uuid primary key default gen_random_uuid(),
  course_id    uuid not null references public.courses (id) on delete cascade,
  code         text not null unique check (code ~ '^[0-9]{1,2}\.[0-9]{1,2}$'),
  title        text not null check (char_length(btrim(title)) between 1 and 200),
  -- Texto de la lección: párrafos separados por línea en blanco; viñetas con "- ".
  content      text not null check (char_length(btrim(content)) between 1 and 20000),
  type         text not null default 'reading' check (type in ('reading', 'practice')),
  sort_order   smallint not null check (sort_order > 0),
  duration_min smallint check (duration_min is null or duration_min between 1 and 120),
  deleted_at   timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  unique (course_id, sort_order)
);
create trigger lessons_set_updated_at before update on public.lessons
  for each row execute function public.set_updated_at();

-- Juegos/dinámicas embebidas. Solo se aceptan URLs de Educaplay para que nadie
-- pueda incrustar páginas arbitrarias en la plataforma.
create table public.lesson_activities (
  id         uuid primary key default gen_random_uuid(),
  lesson_id  uuid not null references public.lessons (id) on delete cascade,
  title      text not null check (char_length(btrim(title)) between 1 and 200),
  provider   text not null default 'educaplay' check (provider in ('educaplay')),
  embed_url  text not null check (embed_url ~ '^https://es\.educaplay\.com/juego/[0-9]+-[A-Za-z0-9_-]+\.html$'),
  sort_order smallint not null default 1 check (sort_order > 0),
  unique (lesson_id, sort_order)
);

create table public.lesson_progress (
  user_id          uuid not null references public.profiles (id) on delete cascade,
  lesson_id        uuid not null references public.lessons (id) on delete cascade,
  status           text not null default 'in_progress' check (status in ('in_progress', 'completed')),
  time_spent_s     integer not null default 0 check (time_spent_s between 0 and 86400),
  last_activity_at timestamptz not null default now(),
  completed_at     timestamptz,
  primary key (user_id, lesson_id),
  check ((status = 'completed') = (completed_at is not null))
);
create index lesson_progress_lesson_id_idx on public.lesson_progress (lesson_id);

-- -----------------------------------------------------------------------------
-- Artículos y fuentes
-- -----------------------------------------------------------------------------

create table public.sources (
  id           uuid primary key default gen_random_uuid(),
  citation     text not null check (char_length(btrim(citation)) between 1 and 400),
  url          text not null unique check (url ~ '^https?://[^\s]+$'),
  consulted_at date
);

create table public.articles (
  id              uuid primary key default gen_random_uuid(),
  lesson_id       uuid not null references public.lessons (id) on delete cascade,
  title           text not null check (char_length(btrim(title)) between 1 and 300),
  summary         text not null check (char_length(btrim(summary)) between 1 and 2000),
  body            text not null check (char_length(btrim(body)) between 1 and 30000),
  author          text not null check (char_length(btrim(author)) between 1 and 300),
  -- Texto libre del documento, p. ej. "2023 (Actualizado en guías de crianza digital)".
  published_label text check (published_label is null or char_length(btrim(published_label)) between 1 and 120),
  is_public       boolean not null default true,
  reviewed_at     date,
  unique (lesson_id, title)
);

create table public.article_sources (
  article_id uuid not null references public.articles (id) on delete cascade,
  source_id  uuid not null references public.sources (id) on delete cascade,
  primary key (article_id, source_id)
);
create index article_sources_source_id_idx on public.article_sources (source_id);

-- -----------------------------------------------------------------------------
-- Evaluaciones
-- -----------------------------------------------------------------------------

-- Un quiz pertenece a una lección (quiz de lección) o a un nivel (evaluación final).
create table public.quizzes (
  id            uuid primary key default gen_random_uuid(),
  lesson_id     uuid references public.lessons (id) on delete cascade,
  course_id     uuid references public.courses (id) on delete cascade,
  title         text not null check (char_length(btrim(title)) between 1 and 200),
  passing_score numeric(5, 2) not null default 70 check (passing_score between 0 and 100),
  is_published  boolean not null default false,
  check (num_nonnulls(lesson_id, course_id) = 1)
);
create unique index quizzes_one_final_per_course on public.quizzes (course_id) where course_id is not null;
create index quizzes_lesson_id_idx on public.quizzes (lesson_id);

create table public.questions (
  id          uuid primary key default gen_random_uuid(),
  quiz_id     uuid not null references public.quizzes (id) on delete cascade,
  statement   text not null check (char_length(btrim(statement)) between 1 and 1000),
  type        text not null default 'single_choice'
              check (type in ('single_choice', 'multiple_choice', 'ordering', 'open')),
  explanation text check (explanation is null or char_length(btrim(explanation)) between 1 and 2000),
  sort_order  smallint not null check (sort_order > 0),
  unique (quiz_id, sort_order)
);

-- is_correct y correct_order NO son visibles para los estudiantes (ver migración 2).
create table public.question_options (
  id            uuid primary key default gen_random_uuid(),
  question_id   uuid not null references public.questions (id) on delete cascade,
  option_text   text not null check (char_length(btrim(option_text)) between 1 and 500),
  is_correct    boolean not null default false,
  correct_order smallint check (correct_order is null or correct_order > 0),
  sort_order    smallint not null check (sort_order > 0),
  unique (question_id, sort_order)
);

create table public.quiz_attempts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  quiz_id     uuid not null references public.quizzes (id) on delete cascade,
  score       numeric(5, 2) not null check (score between 0 and 100),
  passed      boolean not null,
  started_at  timestamptz not null default now(),
  finished_at timestamptz not null default now(),
  check (finished_at >= started_at)
);
create index quiz_attempts_user_quiz_idx on public.quiz_attempts (user_id, quiz_id);
create index quiz_attempts_quiz_id_idx on public.quiz_attempts (quiz_id);

create table public.quiz_answers (
  id           uuid primary key default gen_random_uuid(),
  attempt_id   uuid not null references public.quiz_attempts (id) on delete cascade,
  question_id  uuid not null references public.questions (id) on delete cascade,
  text_answer  text check (text_answer is null or char_length(text_answer) <= 5000),
  score_earned numeric(5, 2) check (score_earned is null or score_earned >= 0),
  unique (attempt_id, question_id)
);
create index quiz_answers_question_id_idx on public.quiz_answers (question_id);

create table public.quiz_answer_options (
  answer_id uuid not null references public.quiz_answers (id) on delete cascade,
  option_id uuid not null references public.question_options (id) on delete cascade,
  primary key (answer_id, option_id)
);
create index quiz_answer_options_option_id_idx on public.quiz_answer_options (option_id);

-- -----------------------------------------------------------------------------
-- Flashcards (predeterminadas por lección)
-- -----------------------------------------------------------------------------

create table public.flashcards (
  id         uuid primary key default gen_random_uuid(),
  lesson_id  uuid not null references public.lessons (id) on delete cascade,
  front      text not null check (char_length(btrim(front)) between 1 and 500),
  back       text not null check (char_length(btrim(back)) between 1 and 1500),
  sort_order smallint not null check (sort_order > 0),
  unique (lesson_id, sort_order)
);

-- Repaso espaciado tipo Leitner: caja 1 (repasar pronto) a 5 (dominada).
create table public.flashcard_reviews (
  user_id        uuid not null references public.profiles (id) on delete cascade,
  card_id        uuid not null references public.flashcards (id) on delete cascade,
  box            smallint not null default 1 check (box between 1 and 5),
  next_review_at timestamptz not null default now(),
  updated_at     timestamptz not null default now(),
  primary key (user_id, card_id)
);
create index flashcard_reviews_card_id_idx on public.flashcard_reviews (card_id);
create trigger flashcard_reviews_set_updated_at before update on public.flashcard_reviews
  for each row execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- Ejercicios críticos (detector de alucinaciones)
-- -----------------------------------------------------------------------------

create table public.critical_exercises (
  id          uuid primary key default gen_random_uuid(),
  lesson_id   uuid not null references public.lessons (id) on delete cascade,
  ai_text     text not null check (char_length(btrim(ai_text)) between 1 and 10000),
  explanation text not null check (char_length(btrim(explanation)) between 1 and 5000)
);
create index critical_exercises_lesson_id_idx on public.critical_exercises (lesson_id);

create table public.critical_exercise_issues (
  id          uuid primary key default gen_random_uuid(),
  exercise_id uuid not null references public.critical_exercises (id) on delete cascade,
  issue_type  text not null check (issue_type in ('hallucination', 'bias', 'false_citation', 'absolute_claim', 'outdated', 'other')),
  fragment    text not null check (char_length(btrim(fragment)) between 1 and 2000),
  explanation text not null check (char_length(btrim(explanation)) between 1 and 2000)
);
create index critical_exercise_issues_exercise_id_idx on public.critical_exercise_issues (exercise_id);

create table public.exercise_attempts (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references public.profiles (id) on delete cascade,
  exercise_id   uuid not null references public.critical_exercises (id) on delete cascade,
  justification text check (justification is null or char_length(justification) <= 5000),
  score         numeric(5, 2) check (score is null or score between 0 and 100),
  created_at    timestamptz not null default now()
);
create index exercise_attempts_user_id_idx on public.exercise_attempts (user_id);
create index exercise_attempts_exercise_id_idx on public.exercise_attempts (exercise_id);

create table public.selected_exercise_issues (
  attempt_id uuid not null references public.exercise_attempts (id) on delete cascade,
  issue_id   uuid not null references public.critical_exercise_issues (id) on delete cascade,
  primary key (attempt_id, issue_id)
);
create index selected_exercise_issues_issue_id_idx on public.selected_exercise_issues (issue_id);

-- -----------------------------------------------------------------------------
-- Evaluador de prompts (escenarios y rúbrica)
-- -----------------------------------------------------------------------------

create table public.scenarios (
  id           uuid primary key default gen_random_uuid(),
  title        text not null check (char_length(btrim(title)) between 1 and 200),
  goal         text not null check (char_length(btrim(goal)) between 1 and 2000),
  is_published boolean not null default false
);

create table public.scenario_criteria (
  id            uuid primary key default gen_random_uuid(),
  scenario_id   uuid not null references public.scenarios (id) on delete cascade,
  criterion_key text not null check (criterion_key ~ '^[a-z][a-z0-9_]{1,40}$'),
  label         text not null check (char_length(btrim(label)) between 1 and 120),
  weight        smallint not null check (weight between 1 and 100),
  sort_order    smallint not null check (sort_order > 0),
  unique (scenario_id, criterion_key),
  unique (scenario_id, sort_order)
);

create table public.scenario_response_templates (
  id            uuid primary key default gen_random_uuid(),
  scenario_id   uuid not null references public.scenarios (id) on delete cascade,
  min_score     smallint not null check (min_score between 0 and 100),
  max_score     smallint not null check (max_score between 0 and 100),
  response_text text not null check (char_length(btrim(response_text)) between 1 and 2000),
  check (min_score <= max_score)
);
create index scenario_response_templates_scenario_id_idx on public.scenario_response_templates (scenario_id);

create table public.prompt_attempts (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null references public.profiles (id) on delete cascade,
  scenario_id uuid not null references public.scenarios (id) on delete cascade,
  score       smallint not null check (score between 0 and 100),
  attempt_no  smallint not null check (attempt_no > 0),
  created_at  timestamptz not null default now(),
  unique (user_id, scenario_id, attempt_no)
);
create index prompt_attempts_scenario_id_idx on public.prompt_attempts (scenario_id);

-- -----------------------------------------------------------------------------
-- Encuestas
-- -----------------------------------------------------------------------------

create table public.surveys (
  id           uuid primary key default gen_random_uuid(),
  type         text not null check (type in ('diagnostic', 'satisfaction', 'feedback')),
  title        text not null check (char_length(btrim(title)) between 1 and 200),
  is_published boolean not null default false
);

create table public.survey_questions (
  id            uuid primary key default gen_random_uuid(),
  survey_id     uuid not null references public.surveys (id) on delete cascade,
  prompt        text not null check (char_length(btrim(prompt)) between 1 and 1000),
  response_type text not null check (response_type in ('single_choice', 'multiple_choice', 'scale', 'text')),
  is_required   boolean not null default true,
  sort_order    smallint not null check (sort_order > 0),
  unique (survey_id, sort_order)
);

create table public.survey_options (
  id            uuid primary key default gen_random_uuid(),
  question_id   uuid not null references public.survey_questions (id) on delete cascade,
  option_text   text not null check (char_length(btrim(option_text)) between 1 and 300),
  numeric_value numeric,
  sort_order    smallint not null check (sort_order > 0),
  unique (question_id, sort_order)
);

create table public.survey_responses (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles (id) on delete cascade,
  survey_id    uuid not null references public.surveys (id) on delete cascade,
  submitted_at timestamptz not null default now()
);
create index survey_responses_user_id_idx on public.survey_responses (user_id);
create index survey_responses_survey_id_idx on public.survey_responses (survey_id);

create table public.survey_answers (
  id            uuid primary key default gen_random_uuid(),
  response_id   uuid not null references public.survey_responses (id) on delete cascade,
  question_id   uuid not null references public.survey_questions (id) on delete cascade,
  text_answer   text check (text_answer is null or char_length(text_answer) <= 5000),
  numeric_value numeric,
  unique (response_id, question_id)
);
create index survey_answers_question_id_idx on public.survey_answers (question_id);

create table public.survey_answer_options (
  answer_id uuid not null references public.survey_answers (id) on delete cascade,
  option_id uuid not null references public.survey_options (id) on delete cascade,
  primary key (answer_id, option_id)
);
create index survey_answer_options_option_id_idx on public.survey_answer_options (option_id);

-- -----------------------------------------------------------------------------
-- Logros (insignias)
-- -----------------------------------------------------------------------------

-- course_id enlaza la insignia de cada nivel; se otorga al aprobar su evaluación final.
create table public.achievements (
  id          uuid primary key default gen_random_uuid(),
  name        text not null unique check (char_length(btrim(name)) between 1 and 100),
  description text not null check (char_length(btrim(description)) between 1 and 500),
  icon        text check (icon is null or icon ~ '^assets/[A-Za-z0-9/_.-]+\.(webp|png|svg)$'),
  course_id   uuid unique references public.courses (id) on delete set null,
  sort_order  smallint not null default 1 check (sort_order > 0)
);

-- Reglas genéricas para insignias que no dependen de un nivel (uso futuro).
create table public.achievement_rule_groups (
  id             uuid primary key default gen_random_uuid(),
  achievement_id uuid not null references public.achievements (id) on delete cascade,
  match_mode     text not null default 'all' check (match_mode in ('all', 'any'))
);
create index achievement_rule_groups_achievement_id_idx on public.achievement_rule_groups (achievement_id);

create table public.achievement_rules (
  id            uuid primary key default gen_random_uuid(),
  rule_group_id uuid not null references public.achievement_rule_groups (id) on delete cascade,
  metric        text not null check (metric in ('lessons_completed', 'quizzes_passed', 'flashcards_mastered', 'prompt_score', 'courses_completed')),
  operator      text not null check (operator in ('>=', '>', '=')),
  target_value  numeric not null check (target_value >= 0)
);
create index achievement_rules_rule_group_id_idx on public.achievement_rules (rule_group_id);

create table public.user_achievements (
  user_id        uuid not null references public.profiles (id) on delete cascade,
  achievement_id uuid not null references public.achievements (id) on delete cascade,
  earned_at      timestamptz not null default now(),
  primary key (user_id, achievement_id)
);
create index user_achievements_achievement_id_idx on public.user_achievements (achievement_id);

-- -----------------------------------------------------------------------------
-- Huella ambiental (valores pendientes de definir; tablas listas)
-- -----------------------------------------------------------------------------

create table public.eco_task_types (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique check (char_length(btrim(name)) between 1 and 100)
);

create table public.eco_factor_versions (
  id           uuid primary key default gen_random_uuid(),
  task_type_id uuid not null references public.eco_task_types (id) on delete cascade,
  water_ml_min numeric not null check (water_ml_min >= 0),
  water_ml_max numeric not null check (water_ml_max >= water_ml_min),
  energy_wh    numeric not null check (energy_wh >= 0),
  valid_from   date not null,
  unique (task_type_id, valid_from)
);

create table public.eco_factor_sources (
  factor_version_id uuid not null references public.eco_factor_versions (id) on delete cascade,
  source_id         uuid not null references public.sources (id) on delete cascade,
  primary key (factor_version_id, source_id)
);
create index eco_factor_sources_source_id_idx on public.eco_factor_sources (source_id);

create table public.eco_estimates (
  id                uuid primary key default gen_random_uuid(),
  user_id           uuid not null references public.profiles (id) on delete cascade,
  factor_version_id uuid not null references public.eco_factor_versions (id) on delete cascade,
  interactions      integer not null check (interactions between 1 and 100000),
  created_at        timestamptz not null default now()
);
create index eco_estimates_user_id_idx on public.eco_estimates (user_id);
create index eco_estimates_factor_version_id_idx on public.eco_estimates (factor_version_id);

-- -----------------------------------------------------------------------------
-- Auditoría de cambios en el contenido
-- -----------------------------------------------------------------------------

create table public.audit_entity_types (
  id   uuid primary key default gen_random_uuid(),
  name text not null unique check (name ~ '^[a-z_]{1,63}$')
);

create table public.audit_logs (
  id             uuid primary key default gen_random_uuid(),
  actor_id       uuid references public.profiles (id) on delete set null,
  entity_type_id uuid not null references public.audit_entity_types (id),
  entity_id      uuid not null,
  action         text not null check (action in ('INSERT', 'UPDATE', 'DELETE')),
  created_at     timestamptz not null default now()
);
create index audit_logs_entity_idx on public.audit_logs (entity_type_id, entity_id);
create index audit_logs_actor_id_idx on public.audit_logs (actor_id);

create table public.audit_log_changes (
  id           uuid primary key default gen_random_uuid(),
  audit_log_id uuid not null references public.audit_logs (id) on delete cascade,
  field_name   text not null,
  old_value    text,
  new_value    text
);
create index audit_log_changes_audit_log_id_idx on public.audit_log_changes (audit_log_id);

-- -----------------------------------------------------------------------------
-- Índices de claves foráneas restantes
-- -----------------------------------------------------------------------------

create index courses_age_group_id_idx on public.courses (age_group_id);
create index lessons_course_id_idx on public.lessons (course_id);
create index lesson_activities_lesson_id_idx on public.lesson_activities (lesson_id);
create index articles_lesson_id_idx on public.articles (lesson_id);
create index questions_quiz_id_idx on public.questions (quiz_id);
create index question_options_question_id_idx on public.question_options (question_id);
create index quiz_answers_attempt_id_idx on public.quiz_answers (attempt_id);
create index flashcards_lesson_id_idx on public.flashcards (lesson_id);
create index scenario_criteria_scenario_id_idx on public.scenario_criteria (scenario_id);
create index prompt_attempts_user_id_idx on public.prompt_attempts (user_id);
create index survey_questions_survey_id_idx on public.survey_questions (survey_id);
create index survey_options_question_id_idx on public.survey_options (question_id);
create index survey_answers_response_id_idx on public.survey_answers (response_id);
create index eco_factor_versions_task_type_id_idx on public.eco_factor_versions (task_type_id);

-- -----------------------------------------------------------------------------
-- Catálogos fijos
-- -----------------------------------------------------------------------------

insert into public.roles (name) values ('student'), ('teacher'), ('admin');

insert into public.audit_entity_types (name) values
  ('courses'), ('lessons'), ('lesson_activities'), ('sources'), ('articles'),
  ('quizzes'), ('questions'), ('question_options'), ('flashcards'), ('achievements');
