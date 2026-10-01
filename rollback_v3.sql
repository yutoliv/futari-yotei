-- ============================================================
-- ふたりの予定帳  v3 を元に戻す（ログインしていない人の読み書きを禁止）
-- Supabase の「SQL Editor」に全部貼り付けて「Run」を1回押してください。
-- 実行後は、ログイン画面がある v2 の index.html に戻してください
-- （v3 の index.html のままだと、予定を読み込めなくなります）。
-- ============================================================

drop policy if exists "events_anon_all" on public.events;
drop policy if exists "profiles_anon_select" on public.profiles;
revoke all on public.events   from anon;
revoke all on public.profiles from anon;
