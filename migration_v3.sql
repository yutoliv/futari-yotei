-- ============================================================
-- ふたりの予定帳  変更 v3：ログインなしで使えるようにする
-- Supabase の「SQL Editor」に全部貼り付けて「Run」を1回押してください。
-- 何回実行しても同じ結果になります。登録済みの予定は消えません。
--
-- ！注意！ これを実行すると、ログインしていない人（anon）も
--   予定を読む・追加・編集・削除できるようになります。
--   アプリのURLや、GitHubに公開している index.html の接続情報を知った人は、
--   誰でも予定を見たり書き換えたりできます。
--   元に戻すときは rollback_v3.sql を実行してください。
-- ============================================================

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
