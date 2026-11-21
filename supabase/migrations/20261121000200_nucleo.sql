-- =====================================================================
-- 02 · Funciones internas (no expuestas a clientes)
--
-- Códigos de error: todas las funciones lanzan errores con un código en
-- MAYÚSCULAS en el mensaje (p. ej. HORARIO_NO_DISPONIBLE) para que la app
-- muestre el texto correspondiente. Ver README.
-- =====================================================================

create function public._settings() returns public.settings
language sql stable security definer set search_path = public, pg_temp as $$
  select * from settings where id
$$;

create function public._new_token() returns text
language sql volatile set search_path = public, pg_temp as $$
  -- 244 bits aleatorios en 64 caracteres hexadecimales
  select replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '')
$$;

create function public._hash(p_token text) returns bytea
language sql immutable set search_path = public, pg_temp as $$
  select sha256(convert_to(coalesce(p_token, ''), 'UTF8'))
$$;

create function public._normalize_phone(p_phone text) returns text
language sql immutable set search_path = public, pg_temp as $$
  select nullif(regexp_replace(coalesce(p_phone, ''), '[^0-9]', '', 'g'), '')
$$;

create function public._set_actor(p_actor text) returns void
language sql volatile set search_path = public, pg_temp as $$
  select set_config('app.actor', p_actor, true)
$$;

create function public.is_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from settings s where s.id and s.owner_user_id is not null and s.owner_user_id = auth.uid()
  )
$$;

create function public._require_admin() returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_admin() then
    raise exception 'NO_AUTORIZADO' using errcode = '42501';
  end if;
end $$;

-- Estados que ocupan la agenda (deben coincidir con agenda_no_overlap)
create function public._is_active_status(p_status text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select p_status in ('pending', 'confirmed', 'completed', 'no_show', 'active')
$$;

-- ¿El rango cae completo dentro de una franja de atención de su día local?
create function public._within_hours(p_period tstzrange) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz        text := (public._settings()).timezone;
  v_start     timestamp := lower(p_period) at time zone v_tz;
  v_end       timestamp := upper(p_period) at time zone v_tz;
begin
  return exists (
    select 1 from working_hours wh
    where wh.weekday = extract(dow from v_start)
      and v_start >= v_start::date + wh.start_time
      and v_end   <= v_start::date + wh.end_time
  );
end $$;

-- ¿Hay algo activo que se superponga con este rango? (ignorando una fila)
create function public._overlaps(p_occupied tstzrange, p_exclude uuid default null) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from agenda a
    where a.occupied && p_occupied
      and public._is_active_status(a.status)
      and a.id is distinct from p_exclude
  )
$$;

-- Lista de horas de inicio posibles para un servicio en un día local.
-- p_exclude: ignora ese turno (para que un cliente pueda mover el suyo).
-- p_apply_rules: aplica anticipación mínima / días hacia adelante / mismo día.
create function public._horarios(
  p_service_id uuid, p_date date, p_exclude uuid default null, p_apply_rules boolean default true
) returns setof timestamptz
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s        public.settings := public._settings();
  svc      public.services;
  wh       record;
  v_today  date := (now() at time zone s.timezone)::date;
  v_min    timestamptz := now() + make_interval(mins => s.min_booking_notice_minutes);
  v_step   interval := make_interval(mins => s.slot_step_minutes);
  v_dur    interval;
  v_occ    interval;
  t        timestamptz;
  v_close  timestamptz;
begin
  select * into svc from services where id = p_service_id and active;
  if not found then return; end if;

  if p_apply_rules then
    if p_date < v_today or p_date > v_today + s.max_booking_days_ahead then return; end if;
    if p_date = v_today and not s.allow_same_day then return; end if;
  end if;

  v_dur := make_interval(mins => svc.duration_minutes);
  v_occ := make_interval(mins => svc.duration_minutes + svc.buffer_minutes);

  for wh in
    select start_time, end_time from working_hours where weekday = extract(dow from p_date) order by start_time
  loop
    t       := (p_date + wh.start_time) at time zone s.timezone;
    v_close := (p_date + wh.end_time)   at time zone s.timezone;
    while t + v_dur <= v_close loop
      if (not p_apply_rules or t >= v_min)
         and not public._overlaps(tstzrange(t, t + v_occ, '[)'), p_exclude) then
        return next t;
      end if;
      t := t + v_step;
    end loop;
  end loop;
end $$;

-- Señal de Realtime "cambió la disponibilidad de tal día" (sin datos personales).
-- Sólo actúa si existe realtime.send (en Supabase existe; en pruebas locales no).
create function public._agenda_broadcast() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_tz  text := (public._settings()).timezone;
  v_row public.agenda := coalesce(new, old);
begin
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null then
    execute 'select realtime.send($1, $2, $3, $4)'
      using jsonb_build_object('fecha', (lower(v_row.period) at time zone v_tz)::date),
            'cambio', 'disponibilidad', false;
  end if;
  return null;
end $$;

create trigger agenda_broadcast after insert or update or delete on public.agenda
  for each row execute function public._agenda_broadcast();

-- Libera la retención de una oferta (si la tiene)
create function public._release_hold(p_hold_id uuid) returns void
language sql volatile security definer set search_path = public, pg_temp as $$
  update agenda set status = 'released'
  where id = p_hold_id and kind = 'hold' and status = 'active'
$$;

-- Cancela las ofertas abiertas de un turno y, si eran de adelanto,
-- sigue ofreciendo ese horario liberado a otros.
create function public._cancel_open_offers(p_appointment_id uuid) returns void
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o public.offers;
begin
  for o in
    select * from offers
    where appointment_id = p_appointment_id and status in ('pending_approval', 'sent')
    for update
  loop
    perform public._release_hold(o.hold_id);
    update offers set status = 'cancelled', responded_at = now() where id = o.id;
    if o.kind = 'advance' then
      perform public._offer_next(o.freed_slot_id);
    end if;
  end loop;
end $$;

-- Encola un aviso push para un cliente (si tiene dispositivos registrados).
create function public._queue_push(
  p_customer_id uuid, p_offer_id uuid, p_kind text, p_title text, p_body text, p_url text
) returns boolean
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  if not exists (select 1 from push_subscriptions where customer_id = p_customer_id) then
    return false;
  end if;
  insert into notification_queue (customer_id, offer_id, kind, title, body, url)
  values (p_customer_id, p_offer_id, p_kind, p_title, p_body, p_url);
  return true;
end $$;
