-- ============================================================
-- আমাদের চ্যাট: নতুন ফিচারের জন্য অতিরিক্ত সেটআপ (একবারই চালাতে হবে)
-- আগের setup.sql চালানো থাকতে হবে। এটা চালালে আগের কিছু মুছবে না।
-- ============================================================

-- ১) মেসেজে নতুন ঘর
alter table public.messages add column if not exists reply_to uuid;
alter table public.messages add column if not exists reactions jsonb not null default '{}'::jsonb;
alter table public.messages add column if not exists edited_at timestamptz;
alter table public.messages add column if not exists pinned boolean not null default false;
alter table public.messages add column if not exists view_once boolean not null default false;
alter table public.messages add column if not exists opened_at timestamptz;
alter table public.messages add column if not exists meta text;

-- ২) নিজের মেসেজ এডিট করার অনুমতি
drop policy if exists "messages edit own" on public.messages;
create policy "messages edit own" on public.messages for update to authenticated
  using (sender = auth.uid()) with check (sender = auth.uid());

-- ৩) নিরাপত্তা পাহারা: অন্যজন শুধু পৌঁছানো/দেখা, পিন, রিঅ্যাকশন ও "খোলা হয়েছে" বদলাতে পারবে
create or replace function public.messages_guard() returns trigger
language plpgsql as $$
begin
  new.sender := old.sender;
  new.created_at := old.created_at;
  if auth.uid() is distinct from old.sender then
    new.body := old.body;
    new.media_path := old.media_path;
    new.media_type := old.media_type;
    new.reply_to := old.reply_to;
    new.edited_at := old.edited_at;
    new.view_once := old.view_once;
    new.meta := old.meta;
  end if;
  return new;
end $$;
drop trigger if exists messages_guard_t on public.messages;
create trigger messages_guard_t before update on public.messages
  for each row execute function public.messages_guard();

-- ৪) রিঅ্যাকশন দেওয়া ও সরানো
create or replace function public.react_msg(mid uuid, emo text) returns void
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then raise exception 'not logged in'; end if;
  update public.messages
     set reactions = case
       when emo is null or emo = '' then coalesce(reactions, '{}'::jsonb) - auth.uid()::text
       else jsonb_set(coalesce(reactions, '{}'::jsonb), array[auth.uid()::text], to_jsonb(emo), true)
     end
   where id = mid;
end $$;
revoke all on function public.react_msg(uuid, text) from public;
grant execute on function public.react_msg(uuid, text) to authenticated;

-- ৫) শেয়ার নোট, করণীয় তালিকা ও কাউন্টডাউন
create table if not exists public.notes (
  id uuid primary key default gen_random_uuid(),
  author uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null default 'todo',
  body text not null,
  done boolean not null default false,
  due date,
  created_at timestamptz not null default now()
);
alter table public.notes enable row level security;
drop policy if exists "notes read" on public.notes;
drop policy if exists "notes add" on public.notes;
drop policy if exists "notes change" on public.notes;
drop policy if exists "notes remove" on public.notes;
create policy "notes read" on public.notes for select to authenticated using (true);
create policy "notes add" on public.notes for insert to authenticated with check (author = auth.uid());
create policy "notes change" on public.notes for update to authenticated using (true) with check (true);
create policy "notes remove" on public.notes for delete to authenticated using (true);

do $$
begin
  begin alter publication supabase_realtime add table public.notes; exception when duplicate_object then null; end;
end $$;
