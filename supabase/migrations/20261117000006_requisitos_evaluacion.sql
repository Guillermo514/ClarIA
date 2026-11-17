-- =============================================================================
-- ClarIA 2.0 · Migración 6: requisitos para presentar la evaluación de un nivel
--
-- Para presentar la evaluación final de un nivel, el estudiante debe:
--   1. Completar todas sus lecciones: cada una se puede marcar después de estar
--      al menos 60 s en ella y de terminar su juego (si tiene).
--   2. Terminar todos sus juegos: se pueden marcar después de 30 s de juego.
--   3. Voltear (ver la respuesta de) todas sus flashcards.
-- Los tiempos los mide el servidor; el progreso solo se registra con las funciones
-- de esta migración. Administradores y docentes no tienen estos requisitos.
-- =============================================================================

-- Tiempos mínimos (segundos).
create or replace function public.min_lesson_seconds() returns integer
language sql immutable set search_path = '' as $$ select 60 $$;

create or replace function public.min_game_seconds() returns integer
language sql immutable set search_path = '' as $$ select 30 $$;

create or replace function public.is_staff()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(public.current_role_name() in ('admin', 'teacher'), false);
$$;

-- -----------------------------------------------------------------------------
-- Tablas y columnas nuevas
-- -----------------------------------------------------------------------------

-- Momento en que el estudiante abrió la lección por primera vez.
alter table public.lesson_progress
  add column started_at timestamptz not null default now();

-- Juegos: cuándo empezó (al pulsar «Jugar») y cuándo lo terminó.
create table public.activity_progress (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  activity_id  uuid not null references public.lesson_activities (id) on delete cascade,
  started_at   timestamptz not null default now(),
  completed_at timestamptz,
  primary key (user_id, activity_id),
  check (completed_at is null or completed_at >= started_at)
);
create index activity_progress_activity_id_idx on public.activity_progress (activity_id);
alter table public.activity_progress enable row level security;

create policy "Ver mi avance en juegos" on public.activity_progress
  for select to authenticated using (user_id = (select auth.uid()));

-- Flashcards: cuándo vio la respuesta por primera vez.
alter table public.flashcard_reviews add column seen_at timestamptz;

-- -----------------------------------------------------------------------------
-- El progreso de lecciones, juegos y tarjetas vistas solo se escribe con funciones
-- -----------------------------------------------------------------------------

drop policy "Registrar mi progreso" on public.lesson_progress;
drop policy "Actualizar mi progreso" on public.lesson_progress;
revoke insert, update, delete on public.lesson_progress from anon, authenticated;
revoke insert, update, delete on public.activity_progress from anon, authenticated;

-- En flashcard_reviews el estudiante sigue manejando su caja de repaso, pero no seen_at.
revoke insert, update on public.flashcard_reviews from anon, authenticated;
grant insert (user_id, card_id, box, next_review_at) on public.flashcard_reviews to authenticated;
grant update (box, next_review_at) on public.flashcard_reviews to authenticated;

-- -----------------------------------------------------------------------------
-- Lecciones
-- -----------------------------------------------------------------------------

-- Registra que el estudiante abrió la lección y devuelve cuánto le falta.
create or replace function public.start_lesson(p_lesson_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user uuid := (select auth.uid());
  v_row  public.lesson_progress;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;
  if not coalesce(public.lesson_is_unlocked(p_lesson_id), false) then
    raise exception 'Esta lección aún está bloqueada' using errcode = '42501';
  end if;

  insert into public.lesson_progress (user_id, lesson_id, status, started_at, last_activity_at)
  values (v_user, p_lesson_id, 'in_progress', now(), now())
  on conflict (user_id, lesson_id) do update set last_activity_at = now()
  returning * into v_row;

  return jsonb_build_object(
    'completed', v_row.status = 'completed',
    'seconds_remaining', case when public.is_staff() then 0
      else greatest(0, public.min_lesson_seconds() - extract(epoch from now() - v_row.started_at))::int end
  );
end;
$$;

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
-- Juegos
-- -----------------------------------------------------------------------------

-- Al pulsar «Jugar». Si aún no lo termina, el tiempo vuelve a empezar.
create or replace function public.start_activity(p_activity_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user   uuid := (select auth.uid());
  v_lesson uuid;
  v_row    public.activity_progress;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;
  select lesson_id into v_lesson from public.lesson_activities where id = p_activity_id;
  if v_lesson is null or not coalesce(public.lesson_is_unlocked(v_lesson), false) then
    raise exception 'Este juego no está disponible' using errcode = '42501';
  end if;

  insert into public.activity_progress (user_id, activity_id, started_at)
  values (v_user, p_activity_id, now())
  on conflict (user_id, activity_id) do update
    set started_at = case when public.activity_progress.completed_at is null
                          then now() else public.activity_progress.started_at end
  returning * into v_row;

  return jsonb_build_object(
    'completed', v_row.completed_at is not null,
    'seconds_remaining', case when v_row.completed_at is not null or public.is_staff() then 0
      else greatest(0, public.min_game_seconds() - extract(epoch from now() - v_row.started_at))::int end
  );
end;
$$;

create or replace function public.complete_activity(p_activity_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user    uuid := (select auth.uid());
  v_started timestamptz;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;

  select started_at into v_started
  from public.activity_progress
  where user_id = v_user and activity_id = p_activity_id;
  if v_started is null then
    raise exception 'Primero abre el juego' using errcode = 'P0001';
  end if;
  if not public.is_staff()
     and now() - v_started < make_interval(secs => public.min_game_seconds()) then
    raise exception 'Juega al menos % segundos antes de terminar', public.min_game_seconds()
      using errcode = 'P0001';
  end if;

  update public.activity_progress
     set completed_at = coalesce(completed_at, now())
   where user_id = v_user and activity_id = p_activity_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- Flashcards
-- -----------------------------------------------------------------------------

-- Al ver la respuesta de una tarjeta (voltearla).
create or replace function public.mark_flashcard_seen(p_card_id uuid)
returns void
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user   uuid := (select auth.uid());
  v_lesson uuid;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;
  select lesson_id into v_lesson from public.flashcards where id = p_card_id;
  if v_lesson is null or not coalesce(public.lesson_is_unlocked(v_lesson), false) then
    raise exception 'Esta tarjeta no está disponible' using errcode = '42501';
  end if;

  insert into public.flashcard_reviews (user_id, card_id, seen_at)
  values (v_user, p_card_id, now())
  on conflict (user_id, card_id) do update
    set seen_at = coalesce(public.flashcard_reviews.seen_at, now());
end;
$$;

-- -----------------------------------------------------------------------------
-- Requisitos del nivel
-- -----------------------------------------------------------------------------

-- Avance del usuario actual en un nivel: lecciones, juegos y flashcards.
create or replace function public.level_progress(p_course_id uuid)
returns table (
  lessons_total     integer,
  lessons_completed integer,
  games_total       integer,
  games_completed   integer,
  flashcards_total  integer,
  flashcards_seen   integer
)
language sql
stable
security definer
set search_path = ''
as $$
  select
    (select count(*)::int from public.lessons l
      where l.course_id = p_course_id and l.deleted_at is null),
    (select count(*)::int from public.lesson_progress lp
       join public.lessons l on l.id = lp.lesson_id
      where l.course_id = p_course_id and lp.user_id = (select auth.uid()) and lp.status = 'completed'),
    (select count(*)::int from public.lesson_activities a
       join public.lessons l on l.id = a.lesson_id
      where l.course_id = p_course_id and l.deleted_at is null),
    (select count(*)::int from public.activity_progress ap
       join public.lesson_activities a on a.id = ap.activity_id
       join public.lessons l on l.id = a.lesson_id
      where l.course_id = p_course_id and ap.user_id = (select auth.uid()) and ap.completed_at is not null),
    (select count(*)::int from public.flashcards f
       join public.lessons l on l.id = f.lesson_id
      where l.course_id = p_course_id and l.deleted_at is null),
    (select count(*)::int from public.flashcard_reviews fr
       join public.flashcards f on f.id = fr.card_id
       join public.lessons l on l.id = f.lesson_id
      where l.course_id = p_course_id and fr.user_id = (select auth.uid()) and fr.seen_at is not null);
$$;

create or replace function public.quiz_requirements_met(p_course_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select public.is_staff() or (
    p.lessons_completed >= p.lessons_total
    and p.games_completed >= p.games_total
    and p.flashcards_seen >= p.flashcards_total
  )
  from public.level_progress(p_course_id) p;
$$;

-- get_my_levels() agrega el avance de juegos y flashcards, y si ya puede presentar.
drop function public.get_my_levels();
create function public.get_my_levels()
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
  games_total       integer,
  games_completed   integer,
  flashcards_total  integer,
  flashcards_seen   integer,
  quiz_ready        boolean,
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
    c.id, c.level_number, c.title, c.objective, g.code, g.name,
    public.course_is_unlocked(c.id),
    coalesce((select bool_or(a.passed) from public.quiz_attempts a
               join public.quizzes q on q.id = a.quiz_id
              where q.course_id = c.id and a.user_id = (select auth.uid())), false),
    (select max(a.score) from public.quiz_attempts a
       join public.quizzes q on q.id = a.quiz_id
      where q.course_id = c.id and a.user_id = (select auth.uid())),
    p.lessons_total, p.lessons_completed, p.games_total, p.games_completed,
    p.flashcards_total, p.flashcards_seen,
    public.is_staff() or (p.lessons_completed >= p.lessons_total
                          and p.games_completed >= p.games_total
                          and p.flashcards_seen >= p.flashcards_total),
    ach.name, ach.icon,
    exists (select 1 from public.user_achievements ua
             where ua.achievement_id = ach.id and ua.user_id = (select auth.uid()))
  from public.courses c
  join public.age_groups g on g.id = c.age_group_id
  cross join lateral public.level_progress(c.id) p
  left join public.achievements ach on ach.course_id = c.id
  where (select auth.uid()) is not null
    and c.is_published and c.deleted_at is null
    and (public.is_staff() or c.age_group_id = public.my_age_group_id())
  order by c.level_number;
$$;

-- -----------------------------------------------------------------------------
-- submit_quiz(): exige los requisitos antes de calificar
-- -----------------------------------------------------------------------------

create or replace function public.check_quiz_requirements()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_course uuid;
begin
  select course_id into v_course from public.quizzes where id = new.quiz_id;
  if v_course is not null and not public.quiz_requirements_met(v_course) then
    raise exception 'Completa todas las lecciones, juegos y flashcards del nivel antes de presentar la evaluación'
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

-- submit_quiz() crea el intento con un INSERT: este trigger lo detiene si faltan requisitos.
create trigger quiz_attempts_check_requirements
  before insert on public.quiz_attempts
  for each row execute function public.check_quiz_requirements();

-- -----------------------------------------------------------------------------
-- Permisos
-- -----------------------------------------------------------------------------

revoke execute on all functions in schema public from public, anon;
grant execute on function public.is_staff(), public.min_lesson_seconds(), public.min_game_seconds()
  to authenticated;
grant execute on function
  public.get_my_levels(), public.level_progress(uuid), public.quiz_requirements_met(uuid),
  public.start_lesson(uuid), public.complete_lesson(uuid),
  public.start_activity(uuid), public.complete_activity(uuid),
  public.mark_flashcard_seen(uuid)
  to authenticated;
-- Las de apoyo a RLS siguen disponibles para anon (las políticas de lectura pública las usan).
grant execute on function
  public.current_role_name(), public.is_admin(), public.my_age_group_id(),
  public.course_is_visible(uuid), public.lesson_is_visible(uuid),
  public.quiz_is_visible(uuid), public.question_is_visible(uuid),
  public.course_is_unlocked(uuid), public.lesson_is_unlocked(uuid)
  to anon;
