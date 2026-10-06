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

-- ---------- 8. ログインなしで使う（v3で追加） ----------
-- 「更新した人」：ログインしていれば本人、していなければ画面で選んだ利用者を記録
create or replace function public.set_event_meta()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    new.created_by := coalesce(auth.uid(), new.updated_by);
    new.created_at := now();
  else
    new.created_by := old.created_by;
    new.created_at := old.created_at;
  end if;
  new.updated_by := coalesce(auth.uid(), new.updated_by);
  new.updated_at := now();
  return new;
end;
$$;

-- ログインしていない人（anon）にも読み書きを許可
grant select, insert, update, delete on public.events   to anon;
grant select                         on public.profiles to anon;

drop policy if exists "events_anon_all" on public.events;
create policy "events_anon_all" on public.events
  for all to anon using (true) with check (true);

drop policy if exists "profiles_anon_select" on public.profiles;
create policy "profiles_anon_select" on public.profiles
  for select to anon using (true);

-- ---------- 9. シフトボードの取り込み（v4で追加） ----------

-- 1. 種類に「シフト」を追加
alter table public.events drop constraint if exists events_kind_check;
alter table public.events add constraint events_kind_check
  check (kind in ('meet', 'due', 'out', 'other', 'shift'));

-- 2. 予定の出どころ（空欄 = 画面から登録、'shiftboard' = シフトボードから取り込み）
alter table public.events add column if not exists source text;
alter table public.events drop constraint if exists events_source_check;
alter table public.events add constraint events_source_check
  check (source is null or source in ('shiftboard'));

create index if not exists events_source_idx on public.events (source, assignee, event_date);

-- 3. 取り込み用の関数
--   p_member : 取り込む人の利用者ID（profiles.id）
--   p_lines  : 1行に1つのシフト。「開始|終了|件名」
--              開始・終了は iPhone の現地時刻で「yyyy-MM-dd HH:mm」
--              例）2026-10-05 17:00|2026-10-05 22:00|〇〇カフェ
--   戻り値   : 登録した件数・削除した件数・読み飛ばした行数
create or replace function public.import_shifts(p_member uuid, p_lines text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  c_days     constant int := 60;                       -- 置き換える範囲（今から何日先まで）
  v_now      timestamp := (now() at time zone 'Asia/Tokyo');
  v_until    timestamp := v_now + make_interval(days => c_days);
  v_line     text;
  v_parts    text[];
  v_title    text;
  v_start    timestamp;
  v_end      timestamp;
  v_all_day  boolean;
  v_end_date date;
  v_inserted int := 0;
  v_deleted  int := 0;
  v_skipped  int := 0;
  v_rows     jsonb := '[]'::jsonb;
  r          jsonb;
begin
  if p_member is null or not exists (select 1 from public.profiles where id = p_member) then
    raise exception '利用者IDが見つかりません: %', p_member using errcode = '22023';
  end if;
  -- 空のデータで全部消えてしまうのを防ぐ（カレンダーを読めなかった場合など）
  if p_lines is null or btrim(p_lines, E' \r\n\t') = '' then
    raise exception 'シフトが1件も送られていません（何も変更していません）' using errcode = '22023';
  end if;
  if char_length(p_lines) > 100000 then
    raise exception '送られたデータが大きすぎます' using errcode = '22023';
  end if;

  -- 3-1. 送られた行を読み取る（読み取れない行は数えて読み飛ばす）
  foreach v_line in array regexp_split_to_array(replace(p_lines, E'\r', ''), E'\n') loop
    v_line := btrim(v_line);
    continue when v_line = '';
    v_parts := regexp_match(v_line, '^(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*\|\s*(\d{4}-\d{2}-\d{2} \d{2}:\d{2})\s*\|(.*)$');
    if v_parts is null then v_skipped := v_skipped + 1; continue; end if;
    begin
      v_start := v_parts[1]::timestamp;
      v_end   := v_parts[2]::timestamp;
    exception when others then
      v_skipped := v_skipped + 1; continue;
    end;
    v_title := left(coalesce(nullif(btrim(v_parts[3]), ''), 'シフト'), 80);
    if v_end < v_start then v_skipped := v_skipped + 1; continue; end if;
    -- 置き換える範囲（今より後に始まり、60日以内）だけを扱う
    continue when v_start < v_now or v_start >= v_until;

    -- 終日の予定：0:00 開始で 24時間近く（23:59 以上）続くもの
    v_all_day := v_start::time = '00:00' and v_end - v_start >= interval '23 hours 59 minutes';
    if v_all_day then
      -- 終了が翌日 0:00 の場合はその前日までとする
      v_end_date := greatest(v_start::date, (v_end - interval '1 minute')::date);
      r := jsonb_build_object('title', v_title, 'event_date', v_start::date, 'end_date', v_end_date,
                              'all_day', true, 'start_time', null, 'end_time', null);
    else
      r := jsonb_build_object('title', v_title, 'event_date', v_start::date, 'end_date', v_end::date,
                              'all_day', false, 'start_time', v_start::time,
                              -- 開始と同じ時刻で終わる予定は終了時刻なし
                              'end_time', case when v_end > v_start then v_end::time end);
    end if;
    v_rows := v_rows || r;
  end loop;

  if jsonb_array_length(v_rows) > 500 then
    raise exception 'シフトが多すぎます（60日で500件まで）' using errcode = '22023';
  end if;

  -- 3-2. これから先 60 日分の「取り込んだシフト」を消す
  delete from public.events e
  where e.source = 'shiftboard'
    and e.assignee = p_member
    and (e.event_date + coalesce(e.start_time, '00:00'::time)) >= v_now
    and (e.event_date + coalesce(e.start_time, '00:00'::time)) <  v_until;
  get diagnostics v_deleted = row_count;

  -- 3-3. シフトボードの内容で登録し直す
  insert into public.events (title, event_date, end_date, all_day, start_time, end_time,
                             kind, assignee, memo, updated_by, source)
  select x.title, x.event_date, x.end_date, x.all_day, x.start_time, x.end_time,
         'shift', p_member, '', p_member, 'shiftboard'
  from jsonb_to_recordset(v_rows)
       as x(title text, event_date date, end_date date, all_day boolean, start_time time, end_time time);
  get diagnostics v_inserted = row_count;

  return jsonb_build_object('inserted', v_inserted, 'deleted', v_deleted, 'skipped', v_skipped);
end;
$$;

-- ショートカット（公開キー＝anon）から呼べるようにする
revoke all on function public.import_shifts(uuid, text) from public;
grant execute on function public.import_shifts(uuid, text) to anon, authenticated;

-- ---------- 10. くり返し登録（v5で追加） ----------
alter table public.events add column if not exists series_id uuid;

create index if not exists events_series_idx on public.events (series_id, event_date);
