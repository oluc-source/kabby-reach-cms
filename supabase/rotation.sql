-- =====================================================================
-- Kabby+ Reach · Rotation des campagnes (à exécuter une fois dans le SQL Editor)
-- À chaque écran, le serveur construit la rotation du jour :
--   spot campagne → contenu maison → spot campagne → contenu maison → …
-- Les campagnes passent à tour de rôle selon leur poids (×1, ×2, ×3),
-- ajusté chaque jour pour atteindre l'objectif d'impressions à la date
-- de fin. Une campagne qui a atteint son objectif s'arrête.
-- =====================================================================
alter table public.campaigns add column if not exists weight smallint not null default 1;
alter table public.campaigns drop constraint if exists campaigns_weight_check;
alter table public.campaigns add constraint campaigns_weight_check check (weight between 1 and 5);

create or replace function public._build_rotation(p_display uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
declare
  today date := (now() at time zone 'Europe/Paris')::date;
  disp public.displays;
  base jsonb := '[]'; a jsonb; pl public.playlists;
  c record;
  ids uuid[] := '{}'; names text[] := '{}'; cnt int[] := '{}'; its jsonb[] := '{}'; info jsonb := '[]';
  cur numeric[]; picks int[]; total int := 0; spots jsonb := '[]';
  i int; k int; best int; n int; nb int; ns int; seq jsonb := '[]';
  delivered numeric; before numeric; pace numeric; tdays int; rdays int; vis jsonb;
begin
  select * into disp from public.displays where id = p_display;
  if not found then return jsonb_build_object('items','[]'::jsonb,'campaigns','[]'::jsonb,'spots',0); end if;

  -- 1. contenus maison : playlists programmées sur l'écran (même logique que le player)
  for a in select x from jsonb_array_elements(coalesce(disp.assignments,'[]')) x
            where case when coalesce(x->>'start','') = '' then true else (x->>'start')::date <= today end
            order by coalesce((x->>'priority')::int,0) desc loop
    if coalesce(a->>'end','') <> '' then
      if (a->>'end')::date < today then continue; end if;
    end if;
    select * into pl from public.playlists where id = (a->>'playlistId')::uuid;
    if not found then continue; end if;
    base := base || coalesce((select jsonb_agg(jsonb_build_object('mediaId', it->>'mediaId', 'duration', coalesce((it->>'duration')::numeric,10)))
                                from jsonb_array_elements(pl.items) it
                               where exists (select 1 from public.media m where m.id::text = it->>'mediaId')), '[]');
    if pl."loop" then exit; end if;
  end loop;

  -- 2. campagnes actives aujourd'hui sur cet écran
  for c in select * from public.campaigns
            where status = 'active' and p_display = any(display_ids) and today between start_date and end_date
            order by start_date, created_at loop
    vis := coalesce((select jsonb_agg(jsonb_build_object('mediaId', it->>'mediaId', 'duration', coalesce((it->>'duration')::numeric,10)))
                       from jsonb_array_elements(c.items) it
                      where exists (select 1 from public.media m where m.id::text = it->>'mediaId')), '[]');
    if jsonb_array_length(vis) = 0 then continue; end if;
    pace := 1;
    if coalesce(c.goal_impressions,0) > 0 then
      select coalesce(sum(x.impressions),0), coalesce(sum(x.impressions) filter (where x.day < today),0)
        into delivered, before from public._campaign_plays(null, null, null, c.id) x;
      if delivered >= c.goal_impressions then
        info := info || jsonb_build_object('id', c.id, 'name', c.name, 'status', 'goal_reached', 'spots', 0, 'pace', 0);
        continue;
      end if;
      tdays := (c.end_date - c.start_date) + 1; rdays := (c.end_date - today) + 1;
      pace := ((c.goal_impressions - before) / rdays) / (c.goal_impressions::numeric / tdays);
      pace := greatest(0.5, least(3, pace));
    end if;
    ids := ids || c.id; names := names || c.name; its := its || vis;
    cnt := cnt || greatest(1, round(c.weight * pace * 2)::int);
    info := info || jsonb_build_object('id', c.id, 'name', c.name, 'status', 'on_air', 'weight', c.weight,
                                       'pace', round(pace, 2), 'spots', greatest(1, round(c.weight * pace * 2)::int));
  end loop;

  n := coalesce(array_length(ids,1), 0);
  if n = 0 then
    return jsonb_build_object('items', base, 'campaigns', info, 'spots', 0, 'day', today);
  end if;

  -- 3. tour de rôle pondéré et lissé (les campagnes ne passent jamais en paquet)
  for i in 1..n loop total := total + cnt[i]; end loop;
  cur := array_fill(0::numeric, array[n]); picks := array_fill(0, array[n]);
  for k in 1..total loop
    best := 1;
    for i in 1..n loop
      cur[i] := cur[i] + cnt[i];
      if cur[i] > cur[best] then best := i; end if;
    end loop;
    cur[best] := cur[best] - total;
    -- les visuels d'une même campagne passent chacun leur tour
    spots := spots || ((its[best] -> (picks[best] % jsonb_array_length(its[best]))) || jsonb_build_object('campaignId', ids[best]));
    picks[best] := picks[best] + 1;
  end loop;

  -- 4. on intercale les contenus maison : spot → maison → spot → maison …
  ns := jsonb_array_length(spots); nb := jsonb_array_length(base);
  if nb = 0 then
    seq := spots;
  else
    for k in 0..least(greatest(ns, nb), 60) - 1 loop
      seq := seq || jsonb_build_array(spots -> (k % ns), base -> (k % nb));
    end loop;
  end if;
  return jsonb_build_object('items', seq, 'campaigns', info, 'spots', ns, 'day', today);
end $$;

-- Synchronisation des players : s'il y a des campagnes à l'antenne, l'écran reçoit
-- la rotation du jour comme playlist prioritaire (valable aujourd'hui seulement :
-- hors ligne après minuit, il retombe sur sa programmation habituelle).
create or replace function public.player_sync(p_player_id text, p_secret text, p_now jsonb default '{}', p_cache jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d public.devices; disp public.displays; pls jsonb; meds jsonb; rot jsonb; rid text;
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
  rot := public._build_rotation(disp.id);
  if coalesce((rot->>'spots')::int, 0) > 0 then
    rid := 'rotation-' || (rot->>'day');
    pls := pls || jsonb_build_array(jsonb_build_object('id', rid, 'name', 'Rotation du jour', 'loop', true, 'rotation', true, 'items', rot->'items'));
    disp.assignments := coalesce(disp.assignments, '[]') || jsonb_build_array(jsonb_build_object(
      'playlistId', rid, 'priority', 1000, 'start', rot->>'day', 'end', rot->>'day'));
  end if;
  select coalesce(jsonb_agg(to_jsonb(m)), '[]') into meds from public.media m
   where m.id::text in (select i->>'mediaId' from jsonb_array_elements(coalesce(pls,'[]')) p, jsonb_array_elements(p->'items') i);
  return jsonb_build_object('paired', true, 'display', to_jsonb(disp), 'playlists', pls, 'media', meds,
                            'command', d.command, 'server_time', now());
end $$;

-- Aperçu de la rotation d'un écran pour le CMS
create or replace function public.rotation_preview(p_display uuid)
returns jsonb language plpgsql stable security definer set search_path = public as $$
begin
  if not public.is_staff() then raise exception 'forbidden' using errcode = '42501'; end if;
  return public._build_rotation(p_display);
end $$;

revoke all on function public._build_rotation(uuid) from public, anon, authenticated;
grant execute on function public.rotation_preview(uuid) to authenticated;
