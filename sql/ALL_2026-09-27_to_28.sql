-- Every migration from 27–28 Sept 2026, executable parts only, in order.
-- Each block is idempotent; the full files with the explanations and the
-- verification queries are next to this one in supabase/migrations/.

-- ===== 20260927120000_chat_escalation_owner_notify.sql =====
begin;

create or replace function public.fn_owner_notify_chat()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_client_name text;
  v_demo        boolean;
  v_body        text;
begin
  if NEW.conversation_state <> 'pending_human'
     or OLD.conversation_state is not distinct from NEW.conversation_state then
    return NEW;
  end if;

  select coalesce(nullif(trim(c.name), ''), nullif(trim(NEW.client_name), ''), 'Un cliente'),
         coalesce(c.is_demo, false)
    into v_client_name, v_demo
    from public.clients c
   where c.id = NEW.client_id;

  if not found then
    v_client_name := coalesce(nullif(trim(NEW.client_name), ''), 'Un cliente');
    v_demo        := false;
  end if;

  if v_demo then
    return NEW;
  end if;

  v_body := v_client_name || ' ha solicitado hablar con personal.';

  begin
    perform net.http_post(
      url     := 'https://eghmgdsoyhfgnjpjhndr.supabase.co/functions/v1/owner-notify',
      headers := jsonb_build_object(
        'x-cron-secret', public.edge_cron_secret(),
        'Content-Type',  'application/json',
        'Authorization', 'Bearer ' || public.fn_anon_key()
      ),
      body := jsonb_build_object(
        'push_body',  'Un cliente está esperando respuesta. Toca para abrir el chat.',
        'type',       'chat',
        'clinic_id',  NEW.clinic_id,
        'client_id',  NEW.client_id,
        'related_id', NEW.id,
        'title',      'Nuevo chat necesita tu atención',
        'body',       v_body
      )
    );
  exception when others then
    raise warning 'fn_owner_notify_chat: % (conversation %)', sqlerrm, NEW.id;
  end;

  return NEW;
end
$fn$;

revoke all on function public.fn_owner_notify_chat() from public, anon, authenticated;

drop trigger if exists trg_owner_notify_chat on public.chat_conversations;
create trigger trg_owner_notify_chat
  after update on public.chat_conversations
  for each row
  when (new.conversation_state = 'pending_human'
        and old.conversation_state is distinct from new.conversation_state)
  execute function public.fn_owner_notify_chat();

commit;

-- ===== 20260927130000_schedule_apply_current_week.sql =====
begin;

create or replace function public.fn_schedule_apply_to_current_week(
  p_worker_id uuid,
  p_today     date
) returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_clinic  uuid;
  v_week    date;
  v_plan    uuid;
  v_dow     int;
  v_date    date;
  v_tpl     record;
  v_day     uuid;
  v_set     int := 0;
  v_cleared int := 0;
begin
  v_clinic := public.fn_plan_owner_clinic();

  if p_today is null
     or p_today < current_date - 1
     or p_today > current_date + 1 then
    raise exception 'p_today must be the current date.' using errcode = '22007';
  end if;

  v_week := p_today - (extract(isodow from p_today)::int - 1);

  select p.id into v_plan
    from public.worker_week_plans p
   where p.worker_id  = p_worker_id
     and p.week_start = v_week
     and p.clinic_id  = v_clinic;

  if v_plan is null then
    return jsonb_build_object('result', 'no_plan', 'week_start', v_week);
  end if;

  for v_dow in 0..6 loop
    v_date := v_week + ((v_dow + 6) % 7);

    if v_date < p_today then
      continue;
    end if;

    select s.start_time, s.end_time
      into v_tpl
      from public.worker_schedules s
     where s.worker_id   = p_worker_id
       and s.clinic_id   = v_clinic
       and s.day_of_week = v_dow
       and coalesce(s.is_active, true)
       and s.end_time > s.start_time
     order by s.start_time
     limit 1;

    if not found then
      delete from public.worker_plan_days
       where plan_id = v_plan and day_of_week = v_dow;
      if found then
        v_cleared := v_cleared + 1;
      end if;
      continue;
    end if;

    insert into public.worker_plan_days (plan_id, day_of_week, start_time, end_time)
    values (v_plan, v_dow, v_tpl.start_time, v_tpl.end_time)
    on conflict (plan_id, day_of_week) do update
      set start_time = excluded.start_time,
          end_time   = excluded.end_time
    returning id into v_day;

    delete from public.worker_plan_breaks where plan_day_id = v_day;

    insert into public.worker_plan_breaks (plan_day_id, start_time, end_time, label)
    select v_day, b.start_time, b.end_time, b.label
      from public.worker_schedule_breaks b
     where b.worker_id   = p_worker_id
       and b.day_of_week = v_dow
       and b.start_time >= v_tpl.start_time
       and b.end_time   <= v_tpl.end_time;

    v_set := v_set + 1;
  end loop;

  update public.worker_week_plans
     set updated_at = now()
   where id = v_plan;

  return jsonb_build_object(
    'result',       'applied',
    'week_start',   v_week,
    'days_set',     v_set,
    'days_cleared', v_cleared
  );
end
$fn$;

grant execute on function public.fn_schedule_apply_to_current_week(uuid, date) to authenticated;
revoke execute on function public.fn_schedule_apply_to_current_week(uuid, date) from anon, public;

commit;

-- ===== 20260927140000_realtime_schedule_tables.sql =====
do $$
declare
  t text;
begin
  foreach t in array array[
    'worker_schedules',           -- the recurring template (Weekly hours)
    'worker_schedule_breaks',     -- its siestas
    'clinic_hours',               -- Opening hours (Settings)
    'clinic_closures',            -- whole-clinic closures, the band above the grid
    'worker_availability_blocks'  -- a worker's time off
  ] loop
    if to_regclass('public.' || t) is null then
      continue;
    end if;
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = t
    ) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end
$$;

select tablename from pg_publication_tables
 where pubname = 'supabase_realtime' order by tablename;

-- ===== 20260927150000_save_fcm_token_ownership.sql =====
begin;

create or replace function public.save_fcm_token(
  p_token       text,
  p_owner_type  text,
  p_owner_id    uuid,
  p_clinic_id   uuid,
  p_platform    text default null,
  p_device_info text default null
) returns void
language plpgsql
volatile
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_uid       uuid := auth.uid();
  v_email     text := lower(trim(coalesce(auth.email(), '')));
  v_role      text;
  v_trusted   boolean;
  v_ok        boolean := false;
  v_row_uid   uuid;
  v_row_email text;
  v_minted    text;   -- the address staff-code-exchange mints for this row
  v_relink    boolean := false;
begin
  if p_owner_type not in ('client', 'clinic_user', 'worker') then
    raise exception 'Invalid owner_type: %', p_owner_type using errcode = '22023';
  end if;
  if p_token is null or length(trim(p_token)) < 20 then
    raise exception 'Invalid token.' using errcode = '22023';
  end if;
  if p_owner_id is null or p_clinic_id is null then
    raise exception 'owner_id and clinic_id are required.' using errcode = '22023';
  end if;

  begin
    v_role := nullif(current_setting('request.jwt.claims', true), '')::json ->> 'role';
  exception when others then
    v_role := null;
  end;
  v_trusted := coalesce(v_role, '') = 'service_role'
            or session_user in ('postgres', 'supabase_admin');

  if p_owner_type = 'client' then
    select c.supabase_uid, lower(trim(coalesce(c.email, '')))
      into v_row_uid, v_row_email
      from public.clients c
     where c.id = p_owner_id and c.clinic_id = p_clinic_id;
    if not found then
      raise exception 'owner_id % not found as client for clinic %', p_owner_id, p_clinic_id
        using errcode = '42501';
    end if;

    v_ok := v_trusted
         or (v_uid is not null and v_row_uid = v_uid)
         or (v_uid is not null and v_row_uid is null
             and v_email <> '' and v_row_email = v_email);

    if v_ok and not v_trusted and v_row_uid is null and not exists (
         select 1 from public.clients o
          where o.clinic_id = p_clinic_id and o.supabase_uid = v_uid and o.id <> p_owner_id
       ) then
      update public.clients
         set supabase_uid = v_uid
       where id = p_owner_id and supabase_uid is null;
    end if;

  elsif p_owner_type = 'clinic_user' then
    select cu.supabase_uid, lower(trim(coalesce(cu.email, '')))
      into v_row_uid, v_row_email
      from public.clinic_users cu
     where cu.id = p_owner_id and cu.clinic_id = p_clinic_id
       and coalesce(cu.is_active, true);
    if not found then
      raise exception 'owner_id % not found as clinic_user for clinic %', p_owner_id, p_clinic_id
        using errcode = '42501';
    end if;

    v_minted := 'cu.' || p_owner_id::text || '@staff.loyaly.invalid';
    if v_uid is not null and v_email = v_minted then
      v_ok := true;
      v_relink := v_row_uid is distinct from v_uid;
    elsif v_uid is not null and v_row_uid = v_uid then
      v_ok := true;
    elsif v_uid is not null and v_row_uid is null
          and v_email <> '' and v_row_email = v_email then
      v_ok := true;
      v_relink := true;
    end if;
    v_ok := v_ok or v_trusted;

    if v_relink and not v_trusted and not exists (
         select 1 from public.clinic_users o
          where o.supabase_uid = v_uid and o.id <> p_owner_id
       ) then
      update public.clinic_users set supabase_uid = v_uid where id = p_owner_id;
    end if;

  else
    select w.supabase_uid
      into v_row_uid
      from public.workers w
     where w.id = p_owner_id and w.clinic_id = p_clinic_id
       and coalesce(w.is_active, true);
    if not found then
      raise exception 'owner_id % not found as worker for clinic %', p_owner_id, p_clinic_id
        using errcode = '42501';
    end if;

    v_minted := 'w.' || p_owner_id::text || '@staff.loyaly.invalid';
    if v_uid is not null and v_email = v_minted then
      v_ok := true;
      v_relink := v_row_uid is distinct from v_uid;
    elsif v_uid is not null and v_row_uid = v_uid then
      v_ok := true;
    end if;
    v_ok := v_ok or v_trusted;

    if v_relink and not v_trusted and not exists (
         select 1 from public.workers o
          where o.supabase_uid = v_uid and o.id <> p_owner_id
       ) then
      update public.workers set supabase_uid = v_uid where id = p_owner_id;
    end if;
  end if;

  if not v_ok then
    raise exception 'Not allowed: you cannot register a push token for this account.'
      using errcode = '42501';
  end if;

  insert into public.fcm_tokens (token, owner_type, owner_id, clinic_id, platform, device_info)
  values (p_token, p_owner_type, p_owner_id, p_clinic_id, p_platform, p_device_info)
  on conflict (token, owner_type, owner_id) do update
    set clinic_id    = excluded.clinic_id,
        platform     = excluded.platform,
        device_info  = excluded.device_info,
        is_active    = true,
        updated_at   = now(),
        last_used_at = now();

  if p_owner_type = 'client' and not v_trusted then
    insert into public.fcm_tokens (token, owner_type, owner_id, clinic_id, platform, device_info)
    select p_token, 'client', c.id, c.clinic_id, p_platform, p_device_info
      from public.clients c
     where c.id <> p_owner_id
       and (
             (v_uid is not null and c.supabase_uid = v_uid)
          or (v_email <> '' and c.supabase_uid is null
              and lower(trim(coalesce(c.email, ''))) = v_email)
           )
    on conflict (token, owner_type, owner_id) do update
      set clinic_id    = excluded.clinic_id,
          platform     = excluded.platform,
          device_info  = excluded.device_info,
          is_active    = true,
          updated_at   = now(),
          last_used_at = now();
  end if;
end
$fn$;

revoke all on function public.save_fcm_token(text, text, uuid, uuid, text, text) from public, anon;
grant execute on function public.save_fcm_token(text, text, uuid, uuid, text, text) to authenticated, service_role;

commit;

-- ===== 20260927160000_drop_slot_overload.sql =====
begin;

drop function if exists public.fn_get_worker_available_slots(uuid, uuid, date, integer, integer);

grant execute on function public.fn_get_worker_available_slots(uuid, uuid, date, integer, integer, uuid)
  to authenticated;

commit;

-- ===== 20260927170000_booking_follows_the_plan.sql =====
begin;

alter table public.clinic_hours
  add column if not exists min_workers integer not null default 1;

alter table public.clinic_hours
  drop constraint if exists clinic_hours_min_workers_positive;
alter table public.clinic_hours
  add constraint clinic_hours_min_workers_positive check (min_workers >= 1);

comment on column public.clinic_hours.min_workers is
  'How many workers must be on shift at any moment this day is open. The '
  'week builder fills the rota up to this number; the client booking screen '
  'does not read it (it counts who is actually free).';

create or replace function public.fn_shift_pref_get(p_week_start date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_clinic uuid; v_owner boolean; v_worker uuid;
  v_mine       jsonb;
  v_mine_from  date;
  v_by_worker  jsonb;
begin
  select c.clinic_id, c.is_owner, c.worker_id
    into v_clinic, v_owner, v_worker
    from public.fn_plan_caller() c;

  v_mine := '[]'::jsonb;
  if v_worker is not null then
    select src.wk into v_mine_from
      from (
        select p.week_start as wk
          from public.worker_shift_preferences p
         where p.worker_id = v_worker and p.week_start <= p_week_start
         order by p.week_start desc
         limit 1
      ) src;

    if v_mine_from is not null then
      select coalesce(jsonb_agg(
               jsonb_build_object('day_of_week', x.day_of_week, 'periods', x.periods)
               order by x.day_of_week), '[]'::jsonb)
        into v_mine
        from (
          select p.day_of_week, jsonb_agg(p.period order by p.period) as periods
            from public.worker_shift_preferences p
           where p.worker_id = v_worker and p.week_start = v_mine_from
           group by p.day_of_week
        ) x;
    end if;
  end if;

  v_by_worker := '[]'::jsonb;
  if v_owner then
    select coalesce(jsonb_agg(w.r order by w.nm), '[]'::jsonb)
      into v_by_worker
      from (
        select wk.name as nm,
               jsonb_build_object(
                 'worker_id',    wk.id,
                 'worker_name',  wk.name,
                 'carried_from', case when src.wk = p_week_start then null else src.wk end,
                 'days',
                   (select coalesce(jsonb_agg(
                             jsonb_build_object('day_of_week', y.day_of_week,
                                                 'periods', y.periods)
                             order by y.day_of_week), '[]'::jsonb)
                      from (
                        select p.day_of_week,
                               jsonb_agg(p.period order by p.period) as periods
                          from public.worker_shift_preferences p
                         where p.worker_id  = wk.id
                           and p.week_start = src.wk
                         group by p.day_of_week
                      ) y)
               ) as r
          from public.workers wk
          join lateral (
                 select p.week_start as wk
                   from public.worker_shift_preferences p
                  where p.worker_id = wk.id and p.week_start <= p_week_start
                  order by p.week_start desc
                  limit 1
               ) src on true
         where wk.clinic_id = v_clinic
           and wk.is_active
      ) w;
  end if;

  return jsonb_build_object(
    'week_start',        p_week_start,
    'is_owner',          coalesce(v_owner, false),
    'mine',              v_mine,
    'mine_carried_from', case when v_mine_from = p_week_start then null else v_mine_from end,
    'by_worker',         v_by_worker);
end
$fn$;

grant execute on function public.fn_shift_pref_get(date) to authenticated;
revoke execute on function public.fn_shift_pref_get(date) from anon, public;

create or replace function public.fn_worker_shift_window(
  p_worker_id uuid,
  p_date      date
)
returns table (start_time time, end_time time)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_clinic uuid;
  v_week   date := (p_date - ((extract(isodow from p_date)::int - 1) || ' days')::interval)::date;
  v_dow    int  := extract(dow from p_date)::int;   -- 0 = Sunday
  v_plan   uuid;
begin
  select w.clinic_id into v_clinic
    from public.workers w
   where w.id = p_worker_id and coalesce(w.is_active, true);
  if v_clinic is null then return; end if;

  if exists (
    select 1 from public.clinic_closures c
     where c.clinic_id = v_clinic
       and c.closed_from < (p_date + 1)::timestamp
       and c.closed_until > p_date::timestamp
  ) then return; end if;

  if exists (
    select 1 from public.worker_availability_blocks b
     where b.worker_id = p_worker_id
       and b.blocked_from  <= p_date::timestamp
       and b.blocked_until >= (p_date + 1)::timestamp
  ) then return; end if;

  select p.id into v_plan
    from public.worker_week_plans p
   where p.worker_id = p_worker_id and p.week_start = v_week;

  if v_plan is not null then
    return query
      select d.start_time, d.end_time
        from public.worker_plan_days d
       where d.plan_id = v_plan and d.day_of_week = v_dow
       limit 1;
    return;
  end if;

  return query
    select s.start_time, s.end_time
      from public.worker_schedules s
     where s.worker_id = p_worker_id
       and s.clinic_id = v_clinic
       and s.day_of_week = v_dow
       and coalesce(s.is_active, true)
       and s.end_time > s.start_time
     order by s.start_time
     limit 1;
end
$fn$;

grant execute on function public.fn_worker_shift_window(uuid, date) to authenticated;
revoke execute on function public.fn_worker_shift_window(uuid, date) from anon, public;

comment on function public.fn_worker_shift_window(uuid, date) is
  'The hours a worker is at the clinic on a date: the dated week plan when '
  'one exists for that week (no row = not working), else the recurring '
  'template. Empty on a clinic closure or a whole-day time-off block. Breaks '
  'are not subtracted -- a client may book during one.';

create or replace function public.fn_worker_is_free(
  p_worker_id uuid,
  p_from      timestamp without time zone,
  p_to        timestamp without time zone,
  p_exclude_booking_id uuid default null
)
returns boolean
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select exists (
           select 1 from public.fn_worker_shift_window(p_worker_id, p_from::date) w
            where p_from::date + w.start_time <= p_from
              and p_from::date + w.end_time   >= p_to
         )
     and not exists (
           select 1 from public.bookings b
            where b.worker_id = p_worker_id
              and b.status not in ('cancelled', 'completed')
              and b.appointment_date is not null
              and (p_exclude_booking_id is null or b.id <> p_exclude_booking_id)
              and b.appointment_date < p_to
              and (b.appointment_date + (coalesce(b.duration_minutes, 60) || ' minutes')::interval) > p_from
         )
     and not exists (
           select 1 from public.worker_availability_blocks wab
            where wab.worker_id = p_worker_id
              and wab.blocked_from < p_to
              and wab.blocked_until > p_from
         );
$fn$;

grant execute on function public.fn_worker_is_free(uuid, timestamp, timestamp, uuid) to authenticated;
revoke execute on function public.fn_worker_is_free(uuid, timestamp, timestamp, uuid) from anon, public;

create or replace function public.fn_get_worker_available_slots(
  p_clinic_id uuid,
  p_worker_id uuid,
  p_date date,
  p_duration_minutes integer,
  p_slot_increment_minutes integer default 30,
  p_exclude_booking_id uuid default null
)
returns table(slot_time timestamp without time zone)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_start_time   time;
  v_end_time     time;
  v_current_slot timestamp;
  v_slot_end     timestamp;
  v_step         interval := (greatest(coalesce(p_slot_increment_minutes, 30), 5) || ' minutes')::interval;
  v_len          interval := (greatest(coalesce(p_duration_minutes, 60), 5) || ' minutes')::interval;
begin
  if not exists (select 1 from public.workers w
                  where w.id = p_worker_id and w.clinic_id = p_clinic_id) then
    return;
  end if;

  select w.start_time, w.end_time into v_start_time, v_end_time
    from public.fn_worker_shift_window(p_worker_id, p_date) w;
  if v_start_time is null then return; end if;

  v_current_slot := p_date + v_start_time;
  while v_current_slot + v_len <= p_date + v_end_time loop
    v_slot_end := v_current_slot + v_len;
    if public.fn_worker_is_free(p_worker_id, v_current_slot, v_slot_end, p_exclude_booking_id) then
      slot_time := v_current_slot;
      return next;
    end if;
    v_current_slot := v_current_slot + v_step;
  end loop;
end
$fn$;

grant execute on function public.fn_get_worker_available_slots(uuid, uuid, date, integer, integer, uuid)
  to authenticated;

create or replace function public.fn_auto_assign_worker(
  p_clinic_id uuid,
  p_service_id uuid,
  p_scheduled_at timestamp without time zone,
  p_duration_minutes integer
)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_chosen   uuid;
  v_to       timestamp := p_scheduled_at + (greatest(coalesce(p_duration_minutes, 60), 5) || ' minutes')::interval;
  v_day_from timestamp := date_trunc('day', p_scheduled_at);
  v_day_to   timestamp := v_day_from + interval '1 day';
begin
  select w.id into v_chosen
    from public.workers w
   where w.clinic_id = p_clinic_id
     and coalesce(w.is_active, true)
     and public.fn_worker_is_free(w.id, p_scheduled_at, v_to)
   order by
     (select count(*) from public.bookings b2
       where b2.worker_id = w.id
         and b2.status not in ('cancelled', 'completed')
         and b2.appointment_date >= v_day_from
         and b2.appointment_date <  v_day_to) asc,
     w.last_assigned_at asc nulls first,
     w.name
   limit 1;

  if v_chosen is not null then
    update public.workers set last_assigned_at = now() where id = v_chosen;
  end if;
  return v_chosen;
end
$fn$;

create or replace function public.fn_booking_day_slots(
  p_clinic_id uuid,
  p_date date,
  p_duration_minutes integer,
  p_slot_increment_minutes integer default 30
)
returns table (slot_time timestamp without time zone, workers_free integer)
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_iso    int := extract(isodow from p_date)::int;
  v_win    record;
  v_opens  time;
  v_closes time;
  v_any    boolean;
  v_cur    timestamp;
  v_end    timestamp;
  v_step   interval := (greatest(coalesce(p_slot_increment_minutes, 30), 5) || ' minutes')::interval;
  v_len    interval := (greatest(coalesce(p_duration_minutes, 60), 5) || ' minutes')::interval;
  v_n      integer;
begin
  if exists (
    select 1 from public.clinic_closures c
     where c.clinic_id = p_clinic_id
       and c.closed_from < (p_date + 1)::timestamp
       and c.closed_until > p_date::timestamp
  ) then return; end if;

  select exists(select 1 from public.clinic_hours h where h.clinic_id = p_clinic_id) into v_any;

  if v_any then
    select * into v_win from public.fn_clinic_open_window(p_clinic_id, v_iso);
    if v_win.is_open is not true or v_win.opens is null or v_win.closes is null then
      return;
    end if;
    v_opens  := v_win.opens;
    v_closes := v_win.closes;
  else
    select min(sw.start_time), max(sw.end_time) into v_opens, v_closes
      from public.workers w
      cross join lateral public.fn_worker_shift_window(w.id, p_date) sw
     where w.clinic_id = p_clinic_id and coalesce(w.is_active, true);
    if v_opens is null then return; end if;
  end if;

  v_cur := p_date + v_opens;
  while v_cur + v_len <= p_date + v_closes loop
    v_end := v_cur + v_len;
    select count(*) into v_n
      from public.workers w
     where w.clinic_id = p_clinic_id
       and coalesce(w.is_active, true)
       and public.fn_worker_is_free(w.id, v_cur, v_end);
    if v_n > 0 then
      slot_time    := v_cur;
      workers_free := v_n;
      return next;
    end if;
    v_cur := v_cur + v_step;
  end loop;
end
$fn$;

grant execute on function public.fn_booking_day_slots(uuid, date, integer, integer) to authenticated;
revoke execute on function public.fn_booking_day_slots(uuid, date, integer, integer) from anon, public;

comment on function public.fn_booking_day_slots(uuid, date, integer, integer) is
  'Bookable start times on a date for the client booking screen: every tick '
  'of the clinic''s open window at which at least one active worker is on '
  'shift (plan or template) and free for the whole duration. workers_free is '
  'that count.';

create or replace function public.fn_booking_workers_at(
  p_clinic_id uuid,
  p_at timestamp without time zone,
  p_duration_minutes integer
)
returns table (worker_id uuid)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select w.id
    from public.workers w
   where w.clinic_id = p_clinic_id
     and coalesce(w.is_active, true)
     and public.fn_worker_is_free(
           w.id, p_at,
           p_at + (greatest(coalesce(p_duration_minutes, 60), 5) || ' minutes')::interval)
   order by w.name;
$fn$;

grant execute on function public.fn_booking_workers_at(uuid, timestamp, integer) to authenticated;
revoke execute on function public.fn_booking_workers_at(uuid, timestamp, integer) from anon, public;

create or replace function public.fn__booking_on_rota()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_from timestamp := new.appointment_date;
  v_to   timestamp;
begin
  if auth.uid() is null
     or coalesce(new.is_demo, false)
     or new.appointment_date is null
     or new.clinic_id is null
     or coalesce(public.fn_staff_is_caller(new.clinic_id), false) then
    return new;
  end if;

  v_to := v_from + (greatest(coalesce(new.duration_minutes, 60), 5) || ' minutes')::interval;

  if new.worker_id is not null then
    if not exists (select 1 from public.workers w
                    where w.id = new.worker_id and w.clinic_id = new.clinic_id
                      and coalesce(w.is_active, true))
       or not public.fn_worker_is_free(new.worker_id, v_from, v_to) then
      raise exception 'worker_not_available'
        using errcode = 'check_violation',
              detail  = 'That professional is not available at this time.',
              hint    = 'Pick another time or another professional.';
    end if;
  else
    new.worker_id := public.fn_auto_assign_worker(new.clinic_id, new.service_id, v_from, new.duration_minutes);
    if new.worker_id is null then
      raise exception 'no_worker_available'
        using errcode = 'check_violation',
              detail  = 'Nobody is available at this time.',
              hint    = 'Pick another time.';
    end if;
    new.assignment_type := coalesce(new.assignment_type, 'random');
  end if;

  if new.worker_name is null then
    select w.name into new.worker_name from public.workers w where w.id = new.worker_id;
  end if;

  return new;
end
$fn$;

drop trigger if exists trg_booking_on_rota on public.bookings;
create trigger trg_booking_on_rota
  before insert on public.bookings
  for each row
  execute function public.fn__booking_on_rota();

comment on function public.fn__booking_on_rota() is
  'A booking made by a client (not staff, not service role) must land on an '
  'active worker who is rostered (week plan, else template) and free for the '
  'whole appointment; with no worker given one is assigned here. Raises '
  'worker_not_available / no_worker_available as stable tokens.';

commit;

-- ===== 20260927180000_points_spend_anywhere.sql =====
begin;

CREATE OR REPLACE FUNCTION public.fn_add_points_internal(p_client_id uuid, p_clinic_id uuid, p_points integer, p_type text, p_description text, p_booking_id uuid DEFAULT NULL::uuid, p_reward_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
AS $function$
DECLARE
  v_tx_id    uuid;
  v_loyalty  int;
  v_lifetime int;
BEGIN
  INSERT INTO points_transactions (
    client_id, clinic_id, points, transaction_type, description, booking_id, reward_id
  )
  VALUES (
    p_client_id, p_clinic_id, p_points, p_type, p_description, p_booking_id, p_reward_id
  )
  RETURNING id INTO v_tx_id;

  PERFORM set_config('app.points_ledger_skip', '1', true); UPDATE clients
  SET loyalty_points  = COALESCE(loyalty_points, 0)  + p_points,
      lifetime_points = COALESCE(lifetime_points, 0) + GREATEST(p_points, 0)  -- only earns raise lifetime
  WHERE id = p_client_id
    AND clinic_id = p_clinic_id
  RETURNING loyalty_points, lifetime_points
  INTO v_loyalty, v_lifetime; PERFORM set_config('app.points_ledger_skip', '0', true);

  IF NOT FOUND THEN
    RAISE EXCEPTION 'fn_add_points: client % not found in clinic %',
      p_client_id, p_clinic_id;
  END IF;

  RETURN jsonb_build_object(
    'transaction_id',  v_tx_id,
    'loyalty_points',  v_loyalty,
    'lifetime_points', v_lifetime
  );
END;
$function$
;

create or replace function public.fn_deduct_points(
  p_client_id   uuid,
  p_clinic_id   uuid,
  p_points      integer,
  p_description text default null,
  p_reward_id   uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $fn_deduct_points$
declare
  v_balance int;
  v_tx_id   uuid;
  v_uid     uuid := auth.uid();
begin
  if p_points is null or p_points <= 0 then
    return jsonb_build_object('success', false, 'error', 'points_must_be_positive');
  end if;

  if v_uid is null then
    return jsonb_build_object('success', false, 'error', 'not_authenticated');
  end if;

  if not (
       exists (select 1 from public.clients c
                where c.id = p_client_id
                  and c.clinic_id = p_clinic_id
                  and c.supabase_uid = v_uid)
    or exists (select 1 from public.clinic_users cu
                where cu.supabase_uid = v_uid
                  and cu.clinic_id = p_clinic_id
                  and cu.is_active)
    or exists (select 1 from public.workers w
                where w.supabase_uid = v_uid
                  and w.clinic_id = p_clinic_id
                  and w.is_active)
  ) then
    return jsonb_build_object('success', false, 'error', 'not_entitled');
  end if;

  select coalesce(loyalty_points, 0)
    into v_balance
    from public.clients
   where id = p_client_id and clinic_id = p_clinic_id
   for update;

  if not found then
    return jsonb_build_object('success', false, 'error', 'client_not_found');
  end if;

  if v_balance < p_points then
    return jsonb_build_object(
      'success', false,
      'error', 'insufficient_points',
      'balance', v_balance, 'available', v_balance,
      'restricted', 0, 'required', p_points);
  end if;

  insert into public.points_transactions
    (client_id, clinic_id, points, transaction_type, description, reward_id)
  values
    (p_client_id, p_clinic_id, -p_points, 'redemption', p_description, p_reward_id)
  returning id into v_tx_id;

  update public.clients
     set loyalty_points    = coalesce(loyalty_points, 0) - p_points,
         restricted_points = 0
   where id = p_client_id and clinic_id = p_clinic_id
  returning loyalty_points into v_balance;

  return jsonb_build_object(
    'success', true,
    'transaction_id', v_tx_id,
    'loyalty_points', v_balance,
    'deducted', p_points
  );
end;
$fn_deduct_points$;

create or replace function public.fn_claim_reward(
  p_client_id uuid,
  p_clinic_id uuid,
  p_reward_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_reward   record;
  v_balance  int;
  v_held     int;
  v_claims   int;
  v_last     timestamptz;
  v_is_vip   boolean;
  v_deduct   jsonb;
begin
  if not coalesce(public.fn_client_is_caller(p_client_id), false) then
    raise exception 'Not allowed: you cannot claim for another client.'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.clients c
                  where c.id = p_client_id and c.clinic_id = p_clinic_id) then
    raise exception 'Not allowed: you are not registered at this clinic.'
      using errcode = '42501';
  end if;

  select r.* into v_reward
    from public.rewards r
   where r.id = p_reward_id
     and r.clinic_id = p_clinic_id
     and coalesce(r.is_active, true);

  if v_reward.id is null then
    return jsonb_build_object('result', 'error', 'reason', 'reward_unavailable');
  end if;

  if not coalesce(public.fn_is_reward_claimable(p_reward_id, p_client_id), false) then
    return jsonb_build_object('result', 'alreadyClaimed');
  end if;

  if coalesce(v_reward.max_claims, 0) > 0
     and not coalesce(v_reward.is_lead_magnet, false) then
    select count(*) into v_claims
      from public.reward_claims rc
     where rc.reward_id = p_reward_id
       and rc.status <> 'cancelled';
    if v_claims >= v_reward.max_claims then
      return jsonb_build_object('result', 'rewardSoldOut');
    end if;
  end if;

  select count(*) into v_held
    from public.reward_claims rc
   where rc.client_id = p_client_id
     and rc.status = 'active'
     and (rc.expires_at is null or rc.expires_at > now());
  if v_held >= 5 then
    return jsonb_build_object('result', 'walletFull');
  end if;

  select exists (select 1 from public.vip_subscriptions vs
                  where vs.client_id = p_client_id and vs.status = 'active')
    into v_is_vip;
  if not v_is_vip then
    select max(pt.created_at) into v_last
      from public.points_transactions pt
     where pt.client_id = p_client_id;
    if v_last is not null and v_last + interval '365 days' < now() then
      return jsonb_build_object('result', 'pointsExpired');
    end if;
  end if;

  select coalesce(c.loyalty_points, 0)
    into v_balance
    from public.clients c where c.id = p_client_id for update;

  if v_balance < coalesce(v_reward.points_required, 0) then
    return jsonb_build_object(
      'result', 'insufficientPoints',
      'balance', v_balance,
      'required', coalesce(v_reward.points_required, 0));
  end if;

  perform set_config('loyaly.claim_via_rpc', '1', true);

  insert into public.reward_claims
    (client_id, clinic_id, reward_id, reward_name, reward_description,
     reward_image_url, reward_type, points_spent, status)
  values
    (p_client_id, p_clinic_id, p_reward_id, v_reward.name, v_reward.description,
     v_reward.primary_image_url, v_reward.reward_type,
     coalesce(v_reward.points_required, 0), 'active');

  perform set_config('loyaly.claim_via_rpc', '0', true);

  if coalesce(v_reward.points_required, 0) > 0 then
    v_deduct := public.fn_deduct_points(
      p_client_id, p_clinic_id, v_reward.points_required,
      'Claimed: ' || coalesce(v_reward.name, 'reward'), p_reward_id);

    if coalesce(v_deduct ->> 'success', 'false') <> 'true' then
      raise exception 'Claim could not be paid for: %',
        coalesce(v_deduct ->> 'error', 'unknown') using errcode = '42501';
    end if;
  end if;

  return jsonb_build_object('result', 'success',
                            'points_spent', coalesce(v_reward.points_required, 0));
end
$fn$;

create or replace function public.fn_claim_product_with_points(
  p_client_id  uuid,
  p_clinic_id  uuid,
  p_product_id uuid
) returns jsonb
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_product record;
  v_balance int;
  v_deduct  jsonb;
begin
  if not coalesce(public.fn_client_is_caller(p_client_id), false) then
    raise exception 'Not allowed: you cannot claim for another client.'
      using errcode = '42501';
  end if;

  if not exists (select 1 from public.clients c
                  where c.id = p_client_id and c.clinic_id = p_clinic_id) then
    raise exception 'Not allowed: you are not registered at this clinic.'
      using errcode = '42501';
  end if;

  select p.* into v_product
    from public.products p
   where p.id = p_product_id
     and p.clinic_id = p_clinic_id
     and coalesce(p.is_active, true)
   for update;

  if v_product.id is null then
    return jsonb_build_object('result', 'error', 'reason', 'product_unavailable');
  end if;

  if coalesce(v_product.points_required, 0) <= 0 then
    return jsonb_build_object('result', 'error', 'reason', 'not_claimable_with_points');
  end if;

  if v_product.stock_quantity is not null and v_product.stock_quantity <= 0 then
    return jsonb_build_object('result', 'rewardSoldOut');
  end if;

  select coalesce(c.loyalty_points, 0)
    into v_balance
    from public.clients c where c.id = p_client_id for update;

  if v_balance < v_product.points_required then
    return jsonb_build_object(
      'result', 'insufficientPoints',
      'balance', v_balance,
      'required', v_product.points_required);
  end if;

  perform set_config('loyaly.claim_via_rpc', '1', true);

  insert into public.reward_claims
    (client_id, clinic_id, product_id, reward_name, reward_description,
     reward_image_url, reward_type, points_spent, status)
  values
    (p_client_id, p_clinic_id, p_product_id, v_product.name, v_product.description,
     v_product.primary_image_url, 'product',
     v_product.points_required, 'pending');

  perform set_config('loyaly.claim_via_rpc', '0', true);

  if v_product.stock_quantity is not null then
    update public.products
       set stock_quantity = greatest(stock_quantity - 1, 0)
     where id = p_product_id;
  end if;

  v_deduct := public.fn_deduct_points(
    p_client_id, p_clinic_id, v_product.points_required,
    'Producto canjeado: ' || coalesce(v_product.name, 'producto'), null);

  if coalesce(v_deduct ->> 'success', 'false') <> 'true' then
    raise exception 'Claim could not be paid for: %',
      coalesce(v_deduct ->> 'error', 'unknown') using errcode = '42501';
  end if;

  return jsonb_build_object('result', 'success',
                            'points_spent', v_product.points_required);
end
$fn$;

update public.clients set restricted_points = 0 where restricted_points <> 0;

comment on column public.clients.restricted_points is
  'Retired 2026-09-27 (20260927180000): always 0. Points from any source '
  'spend on anything. Kept so older app builds that read it keep working.';

revoke all on function public.fn_deduct_points(uuid, uuid, integer, text, uuid) from public, anon;
grant execute on function public.fn_deduct_points(uuid, uuid, integer, text, uuid) to authenticated;
grant execute on function public.fn_claim_reward(uuid, uuid, uuid) to authenticated;
revoke execute on function public.fn_claim_reward(uuid, uuid, uuid) from anon, public;
grant execute on function public.fn_claim_product_with_points(uuid, uuid, uuid) to authenticated;
revoke execute on function public.fn_claim_product_with_points(uuid, uuid, uuid) from anon, public;

commit;

-- ===== 20260928100000_manager_own_calendar.sql =====
begin;

alter table public.clinic_users drop constraint if exists clinic_users_role_check;
alter table public.clinic_users
  add constraint clinic_users_role_check
  check (role = any (array['owner'::text, 'manager'::text, 'worker'::text]));

create or replace function public.fn_manager_ensure_worker_row(p_clinic_user_id uuid)
returns uuid
language plpgsql
volatile
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_cu    public.clinic_users;
  v_email text;
  v_id    uuid;
begin
  select * into v_cu from public.clinic_users where id = p_clinic_user_id;
  if v_cu.id is null or v_cu.role <> 'manager' or not coalesce(v_cu.is_active, true) then
    return null;
  end if;
  v_email := nullif(lower(trim(coalesce(v_cu.email, ''))), '');
  if v_email is null then
    return null;   -- no pairing key; nothing to pair
  end if;

  select w.id into v_id
    from public.workers w
   where w.clinic_id = v_cu.clinic_id and lower(w.email) = v_email
   limit 1;
  if v_id is not null then
    update public.workers set is_active = true where id = v_id and not coalesce(is_active, true);
    return v_id;
  end if;

  insert into public.workers (clinic_id, name, email, role_title, is_active, access_code)
  values (v_cu.clinic_id, coalesce(nullif(trim(v_cu.name), ''), 'Manager'), v_email,
          'Manager', true, public.fn_generate_access_code())
  returning id into v_id;
  return v_id;
end
$fn$;

revoke all on function public.fn_manager_ensure_worker_row(uuid) from public, anon, authenticated;

create or replace function public.fn__manager_worker_row()
returns trigger
language plpgsql
security definer
set search_path to 'public', 'pg_temp'
as $fn$
begin
  if new.role = 'manager' and coalesce(new.is_active, true) then
    perform public.fn_manager_ensure_worker_row(new.id);
  end if;
  return new;
end
$fn$;

drop trigger if exists trg_manager_worker_row on public.clinic_users;
create trigger trg_manager_worker_row
  after insert or update of role, is_active, email on public.clinic_users
  for each row
  execute function public.fn__manager_worker_row();

select public.fn_manager_ensure_worker_row(cu.id)
  from public.clinic_users cu
 where cu.role = 'manager' and coalesce(cu.is_active, true);

create or replace function public.fn_my_worker_row()
returns table (worker_id uuid, clinic_id uuid)
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select w.id, w.clinic_id
    from public.workers w
   where w.supabase_uid = auth.uid()
     and w.is_active
  union all
  select w.id, w.clinic_id
    from public.clinic_users cu
    join public.workers w
      on w.clinic_id = cu.clinic_id
     and lower(w.email) = lower(cu.email)
     and w.is_active
   where cu.supabase_uid = auth.uid()
     and cu.is_active
     and not exists (select 1 from public.workers x
                      where x.supabase_uid = auth.uid() and x.is_active)
  limit 1;
$fn$;

revoke all on function public.fn_my_worker_row() from public, anon, authenticated;

create or replace function public.fn_staff_my_worker()
returns jsonb
language sql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
  select coalesce(
    (select jsonb_build_object('worker_id', r.worker_id, 'clinic_id', r.clinic_id,
                               'name', w.name)
       from public.fn_my_worker_row() r
       join public.workers w on w.id = r.worker_id
      limit 1),
    jsonb_build_object('worker_id', null, 'clinic_id', null, 'name', null));
$fn$;

grant execute on function public.fn_staff_my_worker() to authenticated;
revoke execute on function public.fn_staff_my_worker() from anon, public;

create or replace function public.fn_shift_pref_get(p_week_start date)
returns jsonb
language plpgsql
stable
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_clinic uuid; v_owner boolean; v_worker uuid;
  v_mine       jsonb;
  v_mine_from  date;
  v_by_worker  jsonb;
begin
  select c.clinic_id, c.is_owner, c.worker_id
    into v_clinic, v_owner, v_worker
    from public.fn_plan_caller() c;

  if v_worker is null then
    select r.worker_id into v_worker from public.fn_my_worker_row() r;
  end if;

  v_mine := '[]'::jsonb;
  if v_worker is not null then
    select src.wk into v_mine_from
      from (
        select p.week_start as wk
          from public.worker_shift_preferences p
         where p.worker_id = v_worker and p.week_start <= p_week_start
         order by p.week_start desc
         limit 1
      ) src;

    if v_mine_from is not null then
      select coalesce(jsonb_agg(
               jsonb_build_object('day_of_week', x.day_of_week, 'periods', x.periods)
               order by x.day_of_week), '[]'::jsonb)
        into v_mine
        from (
          select p.day_of_week, jsonb_agg(p.period order by p.period) as periods
            from public.worker_shift_preferences p
           where p.worker_id = v_worker and p.week_start = v_mine_from
           group by p.day_of_week
        ) x;
    end if;
  end if;

  v_by_worker := '[]'::jsonb;
  if v_owner then
    select coalesce(jsonb_agg(w.r order by w.nm), '[]'::jsonb)
      into v_by_worker
      from (
        select wk.name as nm,
               jsonb_build_object(
                 'worker_id',    wk.id,
                 'worker_name',  wk.name,
                 'carried_from', case when src.wk = p_week_start then null else src.wk end,
                 'days',
                   (select coalesce(jsonb_agg(
                             jsonb_build_object('day_of_week', y.day_of_week,
                                                 'periods', y.periods)
                             order by y.day_of_week), '[]'::jsonb)
                      from (
                        select p.day_of_week,
                               jsonb_agg(p.period order by p.period) as periods
                          from public.worker_shift_preferences p
                         where p.worker_id  = wk.id
                           and p.week_start = src.wk
                         group by p.day_of_week
                      ) y)
               ) as r
          from public.workers wk
          join lateral (
                 select p.week_start as wk
                   from public.worker_shift_preferences p
                  where p.worker_id = wk.id and p.week_start <= p_week_start
                  order by p.week_start desc
                  limit 1
               ) src on true
         where wk.clinic_id = v_clinic
           and wk.is_active
      ) w;
  end if;

  return jsonb_build_object(
    'week_start',        p_week_start,
    'is_owner',          coalesce(v_owner, false),
    'mine',              v_mine,
    'mine_carried_from', case when v_mine_from = p_week_start then null else v_mine_from end,
    'by_worker',         v_by_worker);
end
$fn$;

grant execute on function public.fn_shift_pref_get(date) to authenticated;
revoke execute on function public.fn_shift_pref_get(date) from anon, public;

create or replace function public.fn_shift_pref_set(
  p_week_start date,
  p_days       jsonb
) returns jsonb
language plpgsql
volatile
security definer
set search_path to 'public', 'pg_temp'
as $fn$
declare
  v_clinic uuid; v_owner boolean; v_worker uuid;
  v_day    jsonb;
  v_period text;
  v_count  int := 0;
begin
  select c.clinic_id, c.is_owner, c.worker_id
    into v_clinic, v_owner, v_worker
    from public.fn_plan_caller() c;

  if v_worker is null then
    select r.worker_id into v_worker from public.fn_my_worker_row() r;
  end if;

  if v_worker is null then
    raise exception 'Not allowed: only a worker sets their own shift preferences.'
      using errcode = '42501';
  end if;

  if extract(isodow from p_week_start) <> 1 then
    raise exception 'week_start must be a Monday.' using errcode = '22007';
  end if;

  if jsonb_typeof(p_days) is distinct from 'array' then
    raise exception 'p_days must be a JSON array.' using errcode = '22023';
  end if;

  delete from public.worker_shift_preferences
   where worker_id = v_worker and week_start = p_week_start;

  for v_day in select * from jsonb_array_elements(p_days)
  loop
    if (v_day->>'day_of_week') is null
       or (v_day->>'day_of_week')::smallint not between 0 and 6 then
      raise exception 'day_of_week must be 0 (Sunday) to 6 (Saturday).'
        using errcode = '22003';
    end if;

    for v_period in select jsonb_array_elements_text(coalesce(v_day->'periods', '[]'::jsonb))
    loop
      if v_period not in ('morning', 'midday', 'afternoon', 'night') then
        raise exception 'Unknown period: %', v_period using errcode = '22023';
      end if;

      insert into public.worker_shift_preferences
        (clinic_id, worker_id, week_start, day_of_week, period)
      values
        (v_clinic, v_worker, p_week_start,
         (v_day->>'day_of_week')::smallint, v_period)
      on conflict (worker_id, week_start, day_of_week, period) do nothing;

      v_count := v_count + 1;
    end loop;
  end loop;

  return jsonb_build_object('result', 'set', 'week_start', p_week_start, 'count', v_count);
end
$fn$;

grant execute on function public.fn_shift_pref_set(date, jsonb) to authenticated;
revoke execute on function public.fn_shift_pref_set(date, jsonb) from anon, public;

commit;

-- ===== 20260928110000_manager_mfa.sql =====
create or replace function public.fn_staff_mfa_required()
returns boolean
language sql
stable
security definer
set search_path to 'pg_catalog', 'pg_temp'
as $fn$
  select exists (
    select 1
      from public.clinic_users cu
      join public.clinics c on c.id = cu.clinic_id
     where cu.supabase_uid = auth.uid()
       and coalesce(cu.is_active, true)
       and cu.role in ('owner', 'manager')
       and c.confirmed_at is not null
  )
  or exists (
    select 1
      from public.workers w
      join public.clinics c on c.id = w.clinic_id
     where w.supabase_uid = auth.uid()
       and coalesce(w.is_active, true)
       and lower(replace(replace(coalesce(w.role_title, ''), 'clinic_', ''), '_', ' ')) = 'manager'
       and c.confirmed_at is not null
  );
$fn$;
