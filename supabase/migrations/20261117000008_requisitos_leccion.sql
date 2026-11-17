-- =============================================================================
-- ClarIA 2.0 · Migración 8: requisitos para completar cada lección
--
-- Además de 60 s de lectura y terminar su juego, para completar una lección el
-- estudiante debe:
--   * voltear todas las flashcards de esa lección, y
--   * leer su artículo: abrirlo y marcarlo como leído tras 60 s.
-- Administradores y docentes no tienen estos requisitos.
-- =============================================================================

create or replace function public.min_article_seconds() returns integer
language sql immutable set search_path = '' as $$ select 60 $$;

-- Artículos: cuándo lo abrió y cuándo lo marcó como leído.
create table public.article_progress (
  user_id      uuid not null references public.profiles (id) on delete cascade,
  article_id   uuid not null references public.articles (id) on delete cascade,
  started_at   timestamptz not null default now(),
  completed_at timestamptz,
  primary key (user_id, article_id),
  check (completed_at is null or completed_at >= started_at)
);
create index article_progress_article_id_idx on public.article_progress (article_id);
alter table public.article_progress enable row level security;

create policy "Ver mi avance en artículos" on public.article_progress
  for select to authenticated using (user_id = (select auth.uid()));
revoke insert, update, delete on public.article_progress from anon, authenticated;

-- -----------------------------------------------------------------------------
-- Artículos
-- -----------------------------------------------------------------------------

-- Al abrir el artículo. Si aún no lo marca como leído, el tiempo vuelve a empezar.
create or replace function public.start_article(p_article_id uuid)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ''
as $$
declare
  v_user   uuid := (select auth.uid());
  v_lesson uuid;
  v_row    public.article_progress;
begin
  if v_user is null then
    raise exception 'Debes iniciar sesión' using errcode = '28000';
  end if;
  select lesson_id into v_lesson from public.articles where id = p_article_id;
  if v_lesson is null or not coalesce(public.lesson_is_unlocked(v_lesson), false) then
    raise exception 'Este artículo no está disponible' using errcode = '42501';
  end if;

  insert into public.article_progress (user_id, article_id, started_at)
  values (v_user, p_article_id, now())
  on conflict (user_id, article_id) do update
    set started_at = case when public.article_progress.completed_at is null
                          then now() else public.article_progress.started_at end
  returning * into v_row;

  return jsonb_build_object(
    'completed', v_row.completed_at is not null,
    'seconds_remaining', case when v_row.completed_at is not null or public.is_staff() then 0
      else greatest(0, public.min_article_seconds() - extract(epoch from now() - v_row.started_at))::int end
  );
end;
$$;

create or replace function public.complete_article(p_article_id uuid)
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
  from public.article_progress
  where user_id = v_user and article_id = p_article_id;
  if v_started is null then
    raise exception 'Primero abre el artículo' using errcode = 'P0001';
  end if;
  if not public.is_staff()
     and now() - v_started < make_interval(secs => public.min_article_seconds()) then
    raise exception 'Lee el artículo al menos % segundos', public.min_article_seconds()
      using errcode = 'P0001';
  end if;

  update public.article_progress
     set completed_at = coalesce(completed_at, now())
   where user_id = v_user and article_id = p_article_id;
end;
$$;

-- -----------------------------------------------------------------------------
-- complete_lesson(): ahora también exige sus flashcards y su artículo
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
  end if;

  insert into public.lesson_progress (user_id, lesson_id, status, started_at, completed_at, last_activity_at)
  values (v_user, p_lesson_id, 'completed', now(), now(), now())
  on conflict (user_id, lesson_id) do update
    set status = 'completed',
        completed_at = coalesce(public.lesson_progress.completed_at, now()),
        last_activity_at = now();
end;
$$;

grant execute on function
  public.min_article_seconds(), public.start_article(uuid), public.complete_article(uuid)
  to authenticated;
revoke execute on function
  public.min_article_seconds(), public.start_article(uuid), public.complete_article(uuid)
  from public, anon;
