-- Kabby+ Reach · Verrouillage des tablettes (application v11 et suivantes)
alter table public.displays add column if not exists kiosk boolean not null default true;
alter table public.displays add column if not exists exit_pin text not null default '1000';
alter table public.displays drop constraint if exists displays_exit_pin_check;
alter table public.displays add constraint displays_exit_pin_check check (exit_pin ~ '^[0-9]{4}$');
