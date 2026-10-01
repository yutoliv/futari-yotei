-- ============================================================
-- ふたりの予定帳  データベース定義（Supabase / PostgreSQL）
-- Supabase の「SQL Editor」にこのファイルの中身を全部貼り付けて
-- 「Run」を1回押してください。
-- ============================================================

-- ---------- 1. 利用者の表示名 ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text not null check (char_length(display_name) between 1 and 20)
);

-- ---------- 2. 予定 ----------
create table if not exists public.events (
  id          uuid primary key default gen_random_uuid(),
  title       text not null check (char_length(title) between 1 and 80),
  event_date  date not null,
  all_day     boolean not null default false,
  start_time  time,
  end_time    time,
  kind        text not null default 'meet'
              check (kind in ('meet', 'due', 'out', 'other')),
  memo        text not null default '' check (char_length(memo) <= 1000),
  created_by  uuid references auth.users (id) on delete set null,
  updated_by  uuid references auth.users (id) on delete set null,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  -- 終日でない予定は開始時刻が必須
  constraint events_time_required check (all_day or start_time is not null),
  -- 終了時刻は開始時刻より後
  constraint events_time_order check (end_time is null or start_time is null or end_time > start_time)
);

create index if not exists events_event_date_idx on public.events (event_date);

-- ---------- 3. 登録者・更新者・日時をサーバー側で自動記録 ----------
-- （画面から送られた値は使わず、ログイン中の利用者IDを必ず記録する）
create or replace function public.set_event_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := auth.uid();
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_by := auth.uid();
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists events_set_meta on public.events;
create trigger events_set_meta
  before insert or update on public.events
  for each row execute function public.set_event_meta();

-- ---------- 4. 権限（ログインした人だけが使える） ----------
revoke all on public.profiles from anon;
revoke all on public.events   from anon;

grant select, insert, update          on public.profiles to authenticated;
grant select, insert, update, delete  on public.events   to authenticated;
grant select, insert, update, delete  on public.profiles to service_role;
grant select, insert, update, delete  on public.events   to service_role;

-- ---------- 5. 行レベルセキュリティ（RLS） ----------
alter table public.profiles enable row level security;
alter table public.events   enable row level security;

-- 表示名：ログインした人は全員分を読める／自分の分だけ登録・変更できる
drop policy if exists "profiles_select" on public.profiles;
create policy "profiles_select" on public.profiles
  for select to authenticated using (true);

drop policy if exists "profiles_insert_own" on public.profiles;
create policy "profiles_insert_own" on public.profiles
  for insert to authenticated with check (id = (select auth.uid()));

drop policy if exists "profiles_update_own" on public.profiles;
create policy "profiles_update_own" on public.profiles
  for update to authenticated
  using (id = (select auth.uid())) with check (id = (select auth.uid()));

-- 予定：ログインした人（＝あなたが作った2人）は全員の予定を読み書きできる
drop policy if exists "events_select" on public.events;
create policy "events_select" on public.events
  for select to authenticated using (true);

drop policy if exists "events_insert" on public.events;
create policy "events_insert" on public.events
  for insert to authenticated with check (true);

drop policy if exists "events_update" on public.events;
create policy "events_update" on public.events
  for update to authenticated using (true) with check (true);

drop policy if exists "events_delete" on public.events;
create policy "events_delete" on public.events
  for delete to authenticated using (true);

-- ---------- 6. リアルタイム更新（相手の変更をすぐ画面に反映） ----------
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'events'
  ) then
    alter publication supabase_realtime add table public.events;
  end if;
end;
$$;

-- ---------- 7. 期間（日をまたぐ予定）・担当（v2で追加） ----------
-- 終了日（開始日は今までどおり event_date）
alter table public.events add column if not exists end_date date;
update public.events set end_date = event_date where end_date is null;
alter table public.events alter column end_date set not null;

-- 担当（空欄 = 2人共通、ユーザーID = その人の予定）
alter table public.events add column if not exists assignee uuid references auth.users (id) on delete set null;

-- ルールを期間予定に合わせて作り直す
alter table public.events drop constraint if exists events_time_order;
alter table public.events drop constraint if exists events_date_order;
alter table public.events drop constraint if exists events_end_time_required;

-- 終了日は開始日と同じか、それより後
alter table public.events add constraint events_date_order
  check (end_date >= event_date);
-- 日をまたぐ時間指定の予定は、終了時刻が必須
alter table public.events add constraint events_end_time_required
  check (all_day or end_date = event_date or end_time is not null);
-- 同じ日の予定は、終了時刻が開始時刻より後
alter table public.events add constraint events_time_order
  check (end_date > event_date or end_time is null or start_time is null or end_time > start_time);

create index if not exists events_end_date_idx on public.events (end_date);
