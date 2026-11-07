-- =====================================================================
-- Kabby+ Reach · Carte des écrans (à exécuter une fois dans le SQL Editor)
-- Les tablettes (application v8 et suivantes) envoient leur position GPS
-- à chaque synchronisation ; on garde la dernière position connue.
-- =====================================================================
alter table public.devices add column if not exists last_pos jsonb;      -- { lat, lon, acc (m), speed (km/h), at (ms) }
alter table public.devices add column if not exists pos_at timestamptz;  -- réception de la dernière position

create or replace function public.player_sync(p_player_id text, p_secret text, p_now jsonb default '{}', p_cache jsonb default '{}')
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare d public.devices; disp public.displays; pls jsonb; meds jsonb; rot jsonb; rid text;
begin
  d := public._player_auth(p_player_id, p_secret);
  update public.devices set last_seen = now(), now_playing = coalesce(p_now,'{}') - 'pos', cache = coalesce(p_cache,'{}'),
         last_pos = case when jsonb_typeof(p_now->'pos'->'lat') = 'number' and jsonb_typeof(p_now->'pos'->'lon') = 'number'
                         then p_now->'pos' else last_pos end,
         pos_at   = case when jsonb_typeof(p_now->'pos'->'lat') = 'number' and jsonb_typeof(p_now->'pos'->'lon') = 'number'
                         then now() else pos_at end
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

