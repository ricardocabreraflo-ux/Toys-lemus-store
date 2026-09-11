-- supabase/migrations/0020_fixed_expenses.sql
-- Ricardo wants a "Finanzas" tab with recurring monthly fixed expenses
-- (rent, salaries, utilities) compared against the current month's real
-- profit, to see his break-even point. Unlike site_settings/promotions,
-- this is internal financial data — admin-only read and write, no
-- public or vendedor access at all. See
-- docs/superpowers/specs/2026-08-21-finanzas-punto-equilibrio-design.md.

create table if not exists public.fixed_expenses (
  id              uuid primary key default gen_random_uuid(),
  name            text not null,
  monthly_amount  numeric(10, 2) not null check (monthly_amount >= 0),
  active          boolean not null default true,
  created_at      timestamptz not null default now()
);

alter table public.fixed_expenses enable row level security;

drop policy if exists "admin only" on public.fixed_expenses;
create policy "admin only" on public.fixed_expenses for all
  to authenticated using (public.is_admin()) with check (public.is_admin());

do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'fixed_expenses'
  ) then
    alter publication supabase_realtime add table public.fixed_expenses;
  end if;
end;
$$;

notify pgrst, 'reload schema';
