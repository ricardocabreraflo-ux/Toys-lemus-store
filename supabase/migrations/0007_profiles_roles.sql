-- supabase/migrations/0007_profiles_roles.sql
-- Roles: every account gets a profile row tagging it admin or vendedor.
-- New accounts are created only via the invite-vendedor Edge Function
-- (admin-only) — there is no public self-registration anymore (see
-- migration 0008 for the products/taxonomy write policies, and the
-- admin.js change that removes the signup UI).

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  role text not null check (role in ('admin', 'vendedor')),
  created_at timestamptz not null default now()
);

alter table public.profiles enable row level security;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.profiles where id = auth.uid() and role = 'admin'
  );
$$;

grant execute on function public.is_admin() to anon, authenticated;

drop policy if exists "read own or admin reads all" on public.profiles;
create policy "read own or admin reads all" on public.profiles
  for select to authenticated
  using (id = auth.uid() or public.is_admin());

-- No insert/update/delete policy: profiles rows are created only by the
-- invite-vendedor Edge Function (service role, bypasses RLS) and by the
-- backfill below.

insert into public.profiles (id, email, role)
select id, email, 'admin'
from auth.users
where email = 'ricardo.cabreraflo@gmail.com'
on conflict (id) do nothing;
