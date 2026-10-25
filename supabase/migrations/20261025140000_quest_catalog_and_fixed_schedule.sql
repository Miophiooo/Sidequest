-- Quests: 1. fix the weak ones (title didn't match, needed luck like a
-- yellow car or winning a game, contradictions, typos, double emojis),
-- 2. add 60 new ones (111 in total), 3. a fixed quest per date.
-- Before, the quest of a day was position mod count, so every new or
-- deactivated quest (e.g. an approved community quest) changed the quest of
-- every day, even the one running.

-- 1. Fixes (same ids, so old posts keep their quest).
update public.daily_quests set emoji = '🚪', title_de = 'Genau hier', title_en = 'Right Here', desc_de = 'Mach ein Foto von dem Ort, an dem du gerade bist.', desc_en = 'Take a photo of the place where you are right now.' where rotation_index = 1 and created_by is null;
update public.daily_quests set emoji = '✨', title_de = 'Alltag, aber besonders', title_en = 'Ordinary, Elevated', desc_de = 'Zeig etwas Alltägliches so, als wär’s besonders.', desc_en = 'Show something ordinary as if it were special.' where rotation_index = 2 and created_by is null;
update public.daily_quests set emoji = '🙌', title_de = 'Heute geschafft', title_en = 'Nailed It Today', desc_de = 'Zeig etwas, das dir heute gut gelungen ist.', desc_en = 'Show something you did really well today.' where rotation_index = 20 and created_by is null;
update public.daily_quests set emoji = '🤪', title_de = 'Heimliche Pose', title_en = 'Secret Pose', desc_de = 'Mach eine lustige Pose, wenn gerade niemand hinschaut.', desc_en = 'Strike a funny pose while nobody is looking.' where rotation_index = 21 and created_by is null;
update public.daily_quests set emoji = '😂', title_de = 'Hat mich zum Lachen gebracht', title_en = 'Made Me Laugh', desc_de = 'Zeig etwas, das dich heute zum Lachen gebracht hat.', desc_en = 'Show something that made you laugh today.' where rotation_index = 22 and created_by is null;
update public.daily_quests set emoji = '💛', title_de = 'Etwas Gelbes', title_en = 'Something Yellow', desc_de = 'Fotografiere das auffälligste Gelb, das du heute findest.', desc_en = 'Photograph the boldest yellow you can find today.' where rotation_index = 23 and created_by is null;
update public.daily_quests set emoji = '🏆', title_de = 'Kleiner Sieg', title_en = 'Small Win', desc_de = 'Zeig einen kleinen Sieg von heute – egal wie klein.', desc_en = 'Show a small win from today – no matter how small.' where rotation_index = 28 and created_by is null;
update public.daily_quests set emoji = '🐸', title_de = 'Froschperspektive', title_en = 'Worm''s-Eye View', desc_de = 'Fotografiere etwas von ganz unten.', desc_en = 'Photograph something from way down low.' where rotation_index = 33 and created_by is null;
update public.daily_quests set emoji = '🥛', title_de = 'Fast leer', title_en = 'Almost Empty', desc_de = 'Zeig etwas, das fast leer ist.', desc_en = 'Show something that is almost empty.' where rotation_index = 35 and created_by is null;
update public.daily_quests set emoji = '🌤️', title_de = 'Gegenlicht', title_en = 'Against the Light', desc_de = 'Fotografiere etwas im Gegenlicht.', desc_en = 'Photograph something against the light.' where rotation_index = 36 and created_by is null;
update public.daily_quests set emoji = '📷', title_de = 'Heute echt', title_en = 'Real Today', desc_de = 'Zeig etwas von heute ohne Schönreden, ohne Filter, ohne Pose.', desc_en = 'Show something from today without polish, filters, or posing.' where rotation_index = 37 and created_by is null;
update public.daily_quests set emoji = '🔀', title_de = 'Plot Twist', title_en = 'Plot Twist', desc_de = 'Zeig einen Moment, der plötzlich ganz anders wirkt als zuerst.', desc_en = 'Show a moment that suddenly feels different than it first did.' where rotation_index = 41 and created_by is null;
update public.daily_quests set emoji = '💫', title_de = 'Nebensache mit Aura', title_en = 'Minor Thing, Major Aura', desc_de = 'Fotografiere etwas Kleines, das plötzlich wichtiger wirkt als alles andere.', desc_en = 'Photograph something small that suddenly feels more important than everything else.' where rotation_index = 44 and created_by is null;
update public.daily_quests set emoji = '🌪️', title_de = 'Stilles Chaos', title_en = 'Quiet Chaos', desc_de = 'Mach ein Bild von etwas, das ruhig aussieht, aber chaotisch wirkt.', desc_en = 'Take a photo of something that looks calm but feels chaotic.' where rotation_index = 46 and created_by is null;

-- 3a. Fixed schedule: one quest per London date.
create table if not exists public.daily_quest_schedule (
  london_date date primary key,
  quest_id uuid not null references public.daily_quests (id),
  created_at timestamptz not null default now()
);
create index if not exists daily_quest_schedule_quest_id_idx
  on public.daily_quest_schedule (quest_id);
alter table public.daily_quest_schedule enable row level security;
create policy "daily quest schedule readable by authenticated"
  on public.daily_quest_schedule for select to authenticated using (true);

-- 3b. Keep what everyone already saw: every day up to today gets the quest
-- of the old rotation (before the new quests change the count).
insert into public.daily_quest_schedule (london_date, quest_id)
select d::date, a.id
from generate_series(date '2025-12-01', date '2026-10-25', interval '1 day') d
join (
  select q.id,
    row_number() over (order by q.rotation_index) - 1 as pos,
    count(*) over () as total
  from public.daily_quests q
  where q.is_active
) a on a.pos = mod(d::date - date '2024-01-01', a.total)
on conflict (london_date) do nothing;

-- 2. New quests.
insert into public.daily_quests (rotation_index, emoji, title_de, title_en, desc_de, desc_en, is_active) values
  (51, '☕', 'Deine Tasse', 'Your Mug', 'Zeig die Tasse oder das Glas, aus dem du heute trinkst.', 'Show the mug or glass you''re drinking from today.', true),
  (52, '🪟', 'Blick aus dem Fenster', 'Window View', 'Fotografiere den Blick aus dem nächsten Fenster.', 'Photograph the view from the nearest window.', true),
  (53, '👟', 'Schuhe von heute', 'Today''s Shoes', 'Zeig die Schuhe, die du heute trägst – mit dem Boden darunter.', 'Show the shoes you''re wearing today – with the ground below.', true),
  (54, '🍪', 'Snack-Zeit', 'Snack Time', 'Zeig deinen aktuellen Snack in seiner besten Pose.', 'Show your current snack in its best pose.', true),
  (55, '🙂', 'Gesicht im Ding', 'Face in Things', 'Finde ein Gesicht in einem Gegenstand – Steckdose, Auto, Wolke …', 'Find a face in an object – a socket, a car, a cloud …', true),
  (56, '⭕', 'Etwas Rundes', 'Something Round', 'Fotografiere den perfektesten Kreis, den du findest.', 'Photograph the most perfect circle you can find.', true),
  (57, '☁️', 'Himmel jetzt', 'Sky Right Now', 'Fotografiere den Himmel genau jetzt.', 'Photograph the sky right now.', true),
  (58, '🖥️', 'Dein Platz', 'Your Desk', 'Zeig deinen Schreibtisch oder Arbeitsplatz genau so, wie er gerade ist.', 'Show your desk or workspace exactly as it is right now.', true),
  (59, '🐾', 'Tierbegegnung', 'Animal Encounter', 'Fotografiere ein Tier, das dir heute begegnet – Plüsch zählt auch.', 'Photograph an animal you meet today – plush counts too.', true),
  (60, '🎨', 'Farbe dreimal', 'Color Times Three', 'Such dir eine Farbe aus und bring sie dreimal in ein Bild.', 'Pick a color and fit it into one photo three times.', true),
  (61, '🌗', 'Schattenspiel', 'Shadow Play', 'Fotografiere einen spannenden Schatten.', 'Photograph an interesting shadow.', true),
  (62, '💧', 'Spiegelung', 'Reflection', 'Fotografiere eine Spiegelung – nur nicht im Spiegel.', 'Photograph a reflection – just not in a mirror.', true),
  (63, '🦅', 'Von oben', 'From Above', 'Fotografiere etwas direkt von oben.', 'Photograph something straight from above.', true),
  (64, '🔬', 'Ganz nah', 'Super Close', 'Geh so nah ran, dass man kaum erkennt, was es ist.', 'Get so close that it''s hard to tell what it is.', true),
  (65, '🤔', 'Rate mal', 'Guess What', 'Mach ein Foto, bei dem deine Freunde raten müssen, was es ist.', 'Take a photo your friends will have to guess.', true),
  (66, '📍', 'Lieblingsplatz', 'Favorite Spot', 'Zeig deinen Lieblingsplatz in der Nähe.', 'Show your favorite spot nearby.', true),
  (67, '🎧', 'Was du gerade hörst', 'What You Hear', 'Fotografiere, woher das Geräusch kommt, das du gerade hörst.', 'Photograph where the sound you''re hearing right now comes from.', true),
  (68, '🤲', 'Hände in Aktion', 'Busy Hands', 'Zeig deine Hände bei dem, was sie gerade tun.', 'Show your hands doing whatever they''re doing right now.', true),
  (69, '⬆️', 'Schau nach oben', 'Look Up', 'Schau nach oben und fotografiere, was über dir ist.', 'Look up and photograph what''s above you.', true),
  (70, '🧱', 'Unter deinen Füßen', 'Under Your Feet', 'Fotografiere den spannendsten Boden, auf dem du heute stehst.', 'Photograph the most interesting ground you stand on today.', true),
  (71, '🔁', 'Muster', 'Pattern', 'Finde ein Muster, das sich wiederholt.', 'Find a pattern that repeats.', true),
  (72, '🏛️', 'Alt trifft neu', 'Old Meets New', 'Zeig etwas Altes direkt neben etwas Neuem.', 'Show something old right next to something new.', true),
  (73, '🐜', 'Klein ganz groß', 'Tiny Made Huge', 'Lass etwas Winziges riesig wirken.', 'Make something tiny look huge.', true),
  (74, '🏗️', 'Mini-Welt', 'Tiny World', 'Bau aus Dingen auf deinem Tisch eine kleine Szene.', 'Build a tiny scene from things on your table.', true),
  (75, '❤️', 'Unverzichtbar', 'Can''t Live Without', 'Zeig einen Gegenstand, ohne den du heute nicht klarkommst.', 'Show an object you couldn''t get through today without.', true),
  (76, '🙃', 'Kopfüber', 'Upside Down', 'Mach ein Foto, das kopfüber besser aussieht.', 'Take a photo that looks better upside down.', true),
  (77, '🔴', 'Rot sehen', 'Seeing Red', 'Fotografiere das röteste Rot in deiner Nähe.', 'Photograph the reddest red near you.', true),
  (78, '💦', 'Wasser', 'Water', 'Zeig Wasser in irgendeiner Form.', 'Show water in any form.', true),
  (79, '🌱', 'Pflanzenfreund', 'Plant Pal', 'Fotografiere eine Pflanze, die heute dein Highlight ist.', 'Photograph a plant that''s your highlight today.', true),
  (80, '🪧', 'Schild des Tages', 'Sign of the Day', 'Finde ein lustiges oder seltsames Schild.', 'Find a funny or strange sign.', true),
  (81, '🤳', 'Selfie ohne Gesicht', 'Faceless Selfie', 'Mach ein Selfie, ohne dein Gesicht zu zeigen.', 'Take a selfie without showing your face.', true),
  (82, '🍝', 'Was gibt''s zu essen?', 'What''s for Dinner?', 'Zeig, was du heute isst oder kochst.', 'Show what you''re eating or cooking today.', true),
  (83, '🍎', 'Stillleben', 'Still Life', 'Arrangiere drei Dinge zu einem Stillleben.', 'Arrange three things into a still life.', true),
  (84, '📏', 'Linien', 'Leading Lines', 'Fotografiere Linien, die ins Bild hineinführen.', 'Photograph lines that lead into the picture.', true),
  (85, '🖼️', 'Bild im Rahmen', 'Frame in a Frame', 'Nutze ein Fenster, eine Tür oder einen Bogen als Rahmen.', 'Use a window, door or arch as a frame.', true),
  (86, '🎢', 'Absichtlich verwackelt', 'Blur on Purpose', 'Mach absichtlich ein verwackeltes Foto, das trotzdem cool aussieht.', 'Take a deliberately blurry photo that still looks cool.', true),
  (87, '🥱', 'Langweilig, aber schön', 'Boring but Beautiful', 'Lass etwas Langweiliges richtig schön aussehen.', 'Make something boring look beautiful.', true),
  (88, '🛣️', 'Dein Weg', 'Your Route', 'Fotografiere einen Moment von deinem heutigen Weg.', 'Photograph a moment from your route today.', true),
  (89, '🏘️', 'Deine Gegend', 'Your Neighborhood', 'Zeig etwas Typisches aus deiner Gegend.', 'Show something typical of your neighborhood.', true),
  (90, '⚖️', 'Passt nicht zusammen', 'Odd Couple', 'Bring zwei Dinge, die überhaupt nicht zusammenpassen, in ein Bild.', 'Fit two things that don''t match at all into one photo.', true),
  (91, '🌈', 'Lieblingsfarbe', 'Favorite Color', 'Fotografiere etwas in deiner Lieblingsfarbe.', 'Photograph something in your favorite color.', true),
  (92, '🔤', 'Dein Buchstabe', 'Your Letter', 'Finde den Anfangsbuchstaben deines Namens irgendwo da draußen.', 'Find the first letter of your name somewhere out there.', true),
  (93, '🔢', 'Zahl des Tages', 'Number of the Day', 'Finde die Zahl des heutigen Datums irgendwo, z. B. eine 25.', 'Find today''s date number somewhere, like a 25.', true),
  (94, '📐', 'Oddly Satisfying', 'Oddly Satisfying', 'Zeig etwas, das perfekt ordentlich ist.', 'Show something perfectly neat.', true),
  (95, '💎', 'Geheimtipp', 'Hidden Gem', 'Zeig einen Ort, den kaum jemand kennt.', 'Show a place hardly anyone knows.', true),
  (96, '🧸', 'Kindheit', 'Childhood', 'Fotografiere etwas, das dich an deine Kindheit erinnert.', 'Photograph something that reminds you of your childhood.', true),
  (97, '💡', 'Heute gelernt', 'Learned Today', 'Zeig etwas, das du heute gelernt oder entdeckt hast.', 'Show something you learned or discovered today.', true),
  (98, '🛋️', 'Pause', 'Break Time', 'Zeig, wie deine Pause gerade aussieht.', 'Show what your break looks like right now.', true),
  (99, '🗝️', 'Vor der Tür', 'Outside the Door', 'Geh vor die Tür und fotografiere das Erste, was dir auffällt.', 'Step outside and photograph the first thing you notice.', true),
  (100, '🟠', 'Farbklecks', 'Pop of Color', 'Finde einen Farbklecks in einer grauen Umgebung.', 'Find a pop of color in a grey place.', true),
  (101, '🗂️', 'Sammlung', 'Collection', 'Zeig eine Sammlung von irgendwas – Stifte, Tassen, Sticker …', 'Show a collection of anything – pens, mugs, stickers …', true),
  (102, '📖', 'Gerade am Lesen', 'Currently Reading', 'Zeig, was du gerade liest – Buch, Schild oder Bildschirm.', 'Show what you''re reading right now – a book, a sign or a screen.', true),
  (103, '🤝', 'Zusammen gemacht', 'Done Together', 'Zeig etwas, das du heute mit jemand anderem gemacht hast.', 'Show something you did with someone else today.', true),
  (104, '🎲', 'Glück gehabt', 'Got Lucky', 'Zeig etwas, bei dem du heute Glück hattest.', 'Show something you got lucky with today.', true),
  (105, '⏭️', 'In fünf Minuten', 'Five Minutes Ahead', 'Fotografiere, was du in fünf Minuten machen wirst.', 'Photograph what you''ll be doing in five minutes.', true),
  (106, '👯', 'Doppelgänger', 'Lookalikes', 'Finde zwei Dinge, die sich überraschend ähnlich sehen.', 'Find two things that look surprisingly alike.', true),
  (107, '🧭', 'Neuer Weg', 'New Path', 'Geh einen Weg, den du noch nie gegangen bist, und zeig, was du findest.', 'Take a path you''ve never taken and show what you find.', true),
  (108, '👕', 'Outfit-Check', 'Outfit Check', 'Zeig dein heutiges Outfit.', 'Show today''s outfit.', true),
  (109, '🕯️', 'Gemütlich', 'Cozy', 'Fotografiere den gemütlichsten Ort, an dem du heute bist.', 'Photograph the coziest place you''re in today.', true),
  (110, '🔦', 'Leuchtet von selbst', 'Glows on Its Own', 'Fotografiere etwas, das von selbst leuchtet.', 'Photograph something that glows on its own.', true)
on conflict (rotation_index) do nothing;

-- 3c. Plans the next days: each day gets the active quest that ran longest
-- ago (never-run quests first, then by rotation_index). Existing days are
-- never changed.
create or replace function internal.fill_daily_quest_schedule(p_days integer default 14)
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_day date;
  v_quest uuid;
  n integer := 0;
begin
  for v_day in
    select d::date
    from generate_series(
      public.active_challenge_day(),
      public.active_challenge_day() + greatest(p_days, 1),
      interval '1 day'
    ) d
  loop
    continue when exists (
      select 1 from public.daily_quest_schedule s where s.london_date = v_day
    );
    select q.id into v_quest
    from public.daily_quests q
    left join lateral (
      select max(s.london_date) as last_day
      from public.daily_quest_schedule s
      where s.quest_id = q.id
    ) used on true
    where q.is_active
    order by used.last_day asc nulls first, q.rotation_index asc
    limit 1;
    exit when v_quest is null;
    insert into public.daily_quest_schedule (london_date, quest_id)
    values (v_day, v_quest);
    n := n + 1;
  end loop;
  return n;
end;
$$;

select internal.fill_daily_quest_schedule(14);

select cron.schedule(
  'daily-quest-schedule',
  '37 0 * * *',
  'select internal.fill_daily_quest_schedule(14)'
);

-- 3d. The app reads the planned quest; the old rotation is only a fallback.
create or replace function public.get_daily_quest(p_london_date date)
returns table(id uuid, title_de text, title_en text, desc_de text, desc_en text, emoji text, author_username text)
language sql
stable
set search_path to 'public'
as $$
  with planned as (
    select q.*
    from daily_quest_schedule s
    join daily_quests q on q.id = s.quest_id
    where s.london_date = p_london_date
  ),
  active as (
    select q.*,
      row_number() over (order by q.rotation_index) - 1 as pos,
      count(*) over () as total
    from daily_quests q
    where q.is_active
  ),
  picked as (
    select p.id, p.title_de, p.title_en, p.desc_de, p.desc_en, p.emoji, p.created_by, 0 as prio
    from planned p
    union all
    select a.id, a.title_de, a.title_en, a.desc_de, a.desc_en, a.emoji, a.created_by, 1 as prio
    from active a
    where a.pos = mod(p_london_date - date '2024-01-01', a.total)
  )
  select pk.id, pk.title_de, pk.title_en, pk.desc_de, pk.desc_en, pk.emoji, up.username
  from picked pk
  left join users_profile up on up.id = pk.created_by
  order by pk.prio
  limit 1
$$;

