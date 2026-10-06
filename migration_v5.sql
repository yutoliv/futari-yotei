-- ============================================================
-- ふたりの予定帳  変更 v5：繰り返し登録（例：水木金の 9:00〜16:00 を1か月）
-- Supabase の「SQL Editor」に全部貼り付けて「Run」を1回押してください。
-- 何回実行しても同じ結果になります。登録済みの予定は消えません。
--
--   ・繰り返しで登録した予定は、1日ずつ別の予定として保存します
--   ・同じ繰り返しで作った予定には、同じ series_id（繰り返しの番号）を付けます
--     → 「この日以降の繰り返しをすべて削除」に使います
--   ・今までの予定は series_id が空欄（繰り返しではない予定）になります
-- ============================================================

alter table public.events add column if not exists series_id uuid;

create index if not exists events_series_idx on public.events (series_id, event_date);
