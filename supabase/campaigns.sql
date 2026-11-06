-- =====================================================================
-- Kabby+ Reach · Campagnes (à exécuter une fois dans le SQL Editor)
-- Une campagne = un annonceur, des visuels, des dates et des écrans.
-- Pendant ses dates, ses visuels s'ajoutent automatiquement à la boucle
-- des écrans choisis, puis en sortent seuls.
-- =====================================================================
create table if not exists public.campaigns (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  advertiser text not null default '',
  start_date date not null default current_date,
  end_date date not null default (current_date + 30),
  status text not null default 'active' check (status in ('active','paused')),
  items jsonb not null default '[]',          -- [{ "mediaId": uuid, "duration": secondes }]
  display_ids uuid[] not null default '{}',   -- écrans de la campagne
  goal_impressions bigint,                    -- objectif facultatif
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  check (end_date >= start_date)
);
alter table public.campaigns enable row level security;
drop policy if exists staff_all on public.campaigns;
create policy staff_all on public.campaigns for all to authenticated using (public.is_staff()) with check (public.is_staff());

-- Synchronisation des players : les campagnes actives de l'écran sont ajoutées
-- comme playlists « 1 passage » de haute priorité, avant la boucle de l'écran.
create or replace function public.player_sync(p_player_id text, p_secret text, p_now jsonb default '{}', p_cache jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d public.devices; disp public.displays; pls jsonb; meds jsonb; cpls jsonb; cass jsonb;
begin
  d := public._player_auth(p_player_id, p_secret);
  update public.devices set last_seen = now(), now_playing = coalesce(p_now,'{}'), cache = coalesce(p_cache,'{}')
  where player_id = p_player_id;
  if d.display_id is null then
    return jsonb_build_object('paired', false, 'command', d.command, 'server_time', now());
  end if;
  select * into disp from public.displays where id = d.display_id;
  select coalesce(jsonb_agg(to_jsonb(p)), '[]') into pls from public.playlists p
   where p.id in (select (a->>'playlistId')::uuid from jsonb_array_elements(disp.assignments) a where a ? 'playlistId');
  -- campagnes en cours ou à venir (le player filtre lui-même par date, même hors ligne)
  select coalesce(jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name, 'loop', false, 'campaign', true, 'items', c.items)
                            order by c.start_date, c.created_at), '[]'),
         coalesce(jsonb_agg(jsonb_build_object('playlistId', c.id, 'campaignId', c.id, 'priority', 1000,
                            'start', c.start_date::text, 'end', c.end_date::text) order by c.start_date, c.created_at), '[]')
    into cpls, cass
    from public.campaigns c
   where c.status = 'active' and disp.id = any(c.display_ids) and c.end_date >= current_date - 1
     and jsonb_array_length(c.items) > 0;
  pls := pls || cpls;
  disp.assignments := coalesce(disp.assignments, '[]') || cass;
  select coalesce(jsonb_agg(to_jsonb(m)), '[]') into meds from public.media m
   where m.id in (select (i->>'mediaId')::uuid from jsonb_array_elements(coalesce(pls,'[]')) p, jsonb_array_elements(p->'items') i);
  return jsonb_build_object('paired', true, 'display', to_jsonb(disp), 'playlists', pls, 'media', meds,
                            'command', d.command, 'server_time', now());
end $$;

-- Diffusions attribuées à une campagne : ses visuels, sur ses écrans, pendant ses dates.
create or replace function public._campaign_plays(p_from date, p_to date, p_display uuid default null, p_campaign uuid default null)
returns table(campaign_id uuid, day date, display_id uuid, plays int, complete int, seconds numeric, impressions numeric)
language sql stable security definer set search_path = public as $$
  select c.id, ps.day, ps.display_id, ps.plays, ps.complete, ps.seconds, ps.plays * coalesce(dd.audience, 1)
    from public.campaigns c
    join public.play_stats ps
      on ps.display_id = any(c.display_ids)
     and ps.media_id in (select (i->>'mediaId')::uuid from jsonb_array_elements(c.items) i)
     and ps.day between c.start_date and c.end_date
    left join public.displays dd on dd.id = ps.display_id
   where (p_from is null or ps.day >= p_from) and (p_to is null or ps.day <= p_to)
     and (p_display is null or ps.display_id = p_display)
     and (p_campaign is null or c.id = p_campaign)
$$;

-- Total par campagne (dates nulles = toute la durée de la campagne)
create or replace function public.report_campaigns(p_from date default null, p_to date default null, p_display uuid default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb;
begin
  if not public.is_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('campaign_id', c.id,
           'plays', coalesce(t.plays,0), 'complete', coalesce(t.complete,0),
           'seconds', coalesce(t.seconds,0), 'impressions', coalesce(t.impressions,0)) order by c.start_date desc), '[]')
    into res
    from public.campaigns c
    left join (select x.campaign_id, sum(x.plays) plays, sum(x.complete) complete, sum(x.seconds) seconds, sum(x.impressions) impressions
                 from public._campaign_plays(p_from, p_to, p_display) x group by x.campaign_id) t on t.campaign_id = c.id;
  return res;
end $$;

-- Bilan détaillé d'une campagne : totaux, par écran, par jour
create or replace function public.report_campaign(p_id uuid, p_from date default null, p_to date default null)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare res jsonb;
begin
  if not public.is_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  with s as (select * from public._campaign_plays(p_from, p_to, null, p_id))
  select jsonb_build_object(
    'totals', (select jsonb_build_object('plays', coalesce(sum(plays),0), 'complete', coalesce(sum(complete),0),
                                         'seconds', coalesce(sum(seconds),0), 'impressions', coalesce(sum(impressions),0)) from s),
    'displays', (select coalesce(jsonb_agg(x order by x.impressions desc), '[]') from
                  (select display_id, sum(plays) plays, sum(complete) complete, sum(seconds) seconds, sum(impressions) impressions from s group by display_id) x),
    'days', (select coalesce(jsonb_agg(x order by x.day), '[]') from
                  (select day, sum(plays) plays, sum(complete) complete, sum(impressions) impressions from s group by day) x)
  ) into res;
  return res;
end $$;

revoke all on function public._campaign_plays(date, date, uuid, uuid) from public, anon, authenticated;
grant execute on function public.report_campaigns(date, date, uuid) to authenticated;
grant execute on function public.report_campaign(uuid, date, date) to authenticated;
