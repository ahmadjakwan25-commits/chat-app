-- ============================================================
-- আমাদের চ্যাট: Supabase সেটআপ (একবারই চালাতে হবে)
-- ============================================================

-- ১) প্রোফাইল (নাম, শেষ দেখা)
create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  name text not null default 'আমি',
  last_seen timestamptz default now()
);

-- ২) মেসেজ
create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  sender uuid not null default auth.uid() references auth.users(id) on delete cascade,
  body text,
  media_path text,
  media_type text,
  created_at timestamptz not null default now(),
  delivered_at timestamptz,
  read_at timestamptz
);
create index if not exists messages_created_idx on public.messages (created_at);

-- ৩) কলের সংকেত (কল শুরু, রিসিভ, শেষ)
create table if not exists public.signals (
  id bigint generated always as identity primary key,
  sender uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind text not null,
  payload jsonb,
  created_at timestamptz not null default now()
);

-- ৪) নিরাপত্তা চালু: শুধু লগইন করা ব্যবহারকারী দেখতে পাবে
alter table public.profiles enable row level security;
alter table public.messages enable row level security;
alter table public.signals enable row level security;

drop policy if exists "profiles read" on public.profiles;
drop policy if exists "profiles insert own" on public.profiles;
drop policy if exists "profiles update own" on public.profiles;
create policy "profiles read" on public.profiles for select to authenticated using (true);
create policy "profiles insert own" on public.profiles for insert to authenticated with check (id = auth.uid());
create policy "profiles update own" on public.profiles for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

drop policy if exists "messages read" on public.messages;
drop policy if exists "messages send" on public.messages;
drop policy if exists "messages mark seen" on public.messages;
drop policy if exists "messages delete own" on public.messages;
create policy "messages read" on public.messages for select to authenticated using (true);
create policy "messages send" on public.messages for insert to authenticated with check (sender = auth.uid());
create policy "messages mark seen" on public.messages for update to authenticated using (sender <> auth.uid()) with check (sender <> auth.uid());
create policy "messages delete own" on public.messages for delete to authenticated using (sender = auth.uid());

drop policy if exists "signals read" on public.signals;
drop policy if exists "signals send" on public.signals;
drop policy if exists "signals delete" on public.signals;
create policy "signals read" on public.signals for select to authenticated using (true);
create policy "signals send" on public.signals for insert to authenticated with check (sender = auth.uid());
create policy "signals delete" on public.signals for delete to authenticated using (true);

-- অন্যের পাঠানো মেসেজে শুধু "পৌঁছেছে/দেখেছে" বদলানো যাবে, লেখা বদলানো যাবে না
create or replace function public.messages_guard() returns trigger
language plpgsql as $$
begin
  if auth.uid() is distinct from old.sender then
    new.body := old.body;
    new.media_path := old.media_path;
    new.media_type := old.media_type;
    new.sender := old.sender;
    new.created_at := old.created_at;
  end if;
  return new;
end $$;
drop trigger if exists messages_guard_t on public.messages;
create trigger messages_guard_t before update on public.messages
  for each row execute function public.messages_guard();

-- ৫) নতুন অ্যাকাউন্ট খুললে প্রোফাইল নিজে তৈরি হবে
create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, name)
  values (new.id, coalesce(nullif(new.raw_user_meta_data->>'name', ''), 'আমি'))
  on conflict (id) do nothing;
  return new;
end $$;
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new_user();

-- ৬) মাত্র দুটি অ্যাকাউন্ট খোলা যাবে, তৃতীয় কেউ পারবে না
create or replace function public.limit_two_users() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if (select count(*) from auth.users) >= 2 then
    raise exception 'only two users allowed';
  end if;
  return new;
end $$;
drop trigger if exists limit_two_users_t on auth.users;
create trigger limit_two_users_t before insert on auth.users
  for each row execute function public.limit_two_users();

-- ৭) ছবি ও ভিডিওর জন্য গোপন স্টোরেজ (সর্বোচ্চ ৫০ MB প্রতি ফাইল)
insert into storage.buckets (id, name, public, file_size_limit)
values ('media', 'media', false, 52428800)
on conflict (id) do nothing;

drop policy if exists "media read" on storage.objects;
drop policy if exists "media upload" on storage.objects;
drop policy if exists "media delete" on storage.objects;
create policy "media read" on storage.objects for select to authenticated using (bucket_id = 'media');
create policy "media upload" on storage.objects for insert to authenticated with check (bucket_id = 'media');
create policy "media delete" on storage.objects for delete to authenticated using (bucket_id = 'media');

-- ৮) রিয়েলটাইম (সাথে সাথে মেসেজ ও কল পৌঁছানোর জন্য)
do $$
begin
  begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.signals; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when duplicate_object then null; end;
end $$;
