-- ============================================================
-- ふたりの予定帳  変更 v2：期間（日をまたぐ予定）・担当
-- Supabase の「SQL Editor」に全部貼り付けて「Run」を1回押してください。
-- 何回実行しても同じ結果になります。登録済みの予定は消えません。
--   ・登録済みの予定 → 終了日 = 開始日、担当 = 2人共通 になります
-- ============================================================

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
