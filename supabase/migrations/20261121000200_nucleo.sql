-- =====================================================================
-- 02 · Funciones internas (no expuestas por la API)
--
-- Errores: código en MAYÚSCULAS en el mensaje (p. ej. HORARIO_NO_DISPONIBLE)
-- para que la app muestre el texto correspondiente. Ver README.
-- =====================================================================

create function public._shop(p_shop_id uuid) returns public.shops
language sql stable security definer set search_path = public, pg_temp as $$
  select * from shops where id = p_shop_id
$$;

create function public._shop_by_slug(p_slug text) returns public.shops
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops;
begin
  select * into s from shops where slug = lower(btrim(coalesce(p_slug, '')));
  if not found then raise exception 'PELUQUERIA_INEXISTENTE'; end if;
  return s;
end $$;

-- ¿La peluquería está aprobada y al día con el pago?
create function public._shop_active(s public.shops) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select s.status = 'active'
         and (s.paid_until is null or s.paid_until >= (now() at time zone s.timezone)::date)
$$;

-- ¿Acepta reservas online ahora?
create function public._shop_open(s public.shops) returns boolean
language sql stable set search_path = public, pg_temp as $$
  select public._shop_active(s) and s.booking_enabled
$$;

create function public._new_token() returns text
language sql volatile set search_path = public, pg_temp as $$
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

-- ---------------------------------------------------------------------
-- Identidad del usuario logueado
-- ---------------------------------------------------------------------
-- Peluquería del usuario logueado (o null). Se usa en las políticas RLS.
create function public.my_shop_id() returns uuid
language sql stable security definer set search_path = public, pg_temp as $$
  select id from shops where owner_user_id = auth.uid()
$$;

create function public.is_platform_admin() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from platform_admins where user_id = auth.uid())
$$;

-- Devuelve la peluquería del peluquero logueado o corta con NO_AUTORIZADO
create function public._require_admin() returns public.shops
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops;
begin
  select * into s from shops where owner_user_id = auth.uid();
  if auth.uid() is null or not found then
    raise exception 'NO_AUTORIZADO' using errcode = '42501';
  end if;
  return s;
end $$;

create function public._require_platform_admin() returns void
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not public.is_platform_admin() then
    raise exception 'NO_AUTORIZADO' using errcode = '42501';
  end if;
end $$;

create function public._is_active_status(p_status text) returns boolean
language sql immutable set search_path = public, pg_temp as $$
  select p_status in ('pending', 'confirmed', 'completed', 'no_show', 'active')
$$;

-- ---------------------------------------------------------------------
-- Agenda y disponibilidad
-- ---------------------------------------------------------------------
create function public._within_hours(p_shop_id uuid, p_period tstzrange) returns boolean
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz    text := (public._shop(p_shop_id)).timezone;
  v_start timestamp := lower(p_period) at time zone v_tz;
  v_end   timestamp := upper(p_period) at time zone v_tz;
begin
  return exists (
    select 1 from working_hours wh
    where wh.shop_id = p_shop_id
      and wh.weekday = extract(dow from v_start)
      and v_start >= v_start::date + wh.start_time
      and v_end   <= v_start::date + wh.end_time
  );
end $$;

create function public._overlaps(p_shop_id uuid, p_occupied tstzrange, p_exclude uuid default null) returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (
    select 1 from agenda a
    where a.shop_id = p_shop_id
      and a.occupied && p_occupied
      and public._is_active_status(a.status)
      and a.id is distinct from p_exclude
  )
$$;

-- Horas de inicio posibles para un servicio en un día local.
create function public._horarios(
  p_service_id uuid, p_date date, p_exclude uuid default null, p_apply_rules boolean default true
) returns setof timestamptz
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  svc      public.services;
  s        public.shops;
  wh       record;
  v_today  date;
  v_min    timestamptz;
  v_step   interval;
  v_dur    interval;
  v_occ    interval;
  t        timestamptz;
  v_close  timestamptz;
begin
  select * into svc from services where id = p_service_id and active;
  if not found then return; end if;
  s := public._shop(svc.shop_id);

  v_today := (now() at time zone s.timezone)::date;
  v_min   := now() + make_interval(mins => s.min_booking_notice_minutes);
  v_step  := make_interval(mins => s.slot_step_minutes);

  if p_apply_rules then
    if p_date < v_today or p_date > v_today + s.max_booking_days_ahead then return; end if;
    if p_date = v_today and not s.allow_same_day then return; end if;
  end if;

  v_dur := make_interval(mins => svc.duration_minutes);
  v_occ := make_interval(mins => svc.duration_minutes + svc.buffer_minutes);

  for wh in
    select start_time, end_time from working_hours
    where shop_id = s.id and weekday = extract(dow from p_date) order by start_time
  loop
    t       := (p_date + wh.start_time) at time zone s.timezone;
    v_close := (p_date + wh.end_time)   at time zone s.timezone;
    while t + v_dur <= v_close loop
      if (not p_apply_rules or t >= v_min)
         and not public._overlaps(s.id, tstzrange(t, t + v_occ, '[)'), p_exclude) then
        return next t;
      end if;
      t := t + v_step;
    end loop;
  end loop;
end $$;

-- Señal de Realtime "cambió la disponibilidad" por peluquería, sin datos personales.
create function public._agenda_broadcast() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_row  public.agenda := coalesce(new, old);
  s      public.shops := public._shop(v_row.shop_id);
begin
  if to_regprocedure('realtime.send(jsonb,text,text,boolean)') is not null then
    execute 'select realtime.send($1, $2, $3, $4)'
      using jsonb_build_object('fecha', (lower(v_row.period) at time zone s.timezone)::date),
            'cambio', 'disponibilidad:' || s.slug, false;
  end if;
  return null;
end $$;

create trigger agenda_broadcast after insert or update or delete on public.agenda
  for each row execute function public._agenda_broadcast();

create function public._release_hold(p_hold_id uuid) returns void
language sql volatile security definer set search_path = public, pg_temp as $$
  update agenda set status = 'released'
  where id = p_hold_id and kind = 'hold' and status = 'active'
$$;

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

create function public._queue_push(
  p_customer_id uuid, p_offer_id uuid, p_kind text, p_title text, p_body text, p_url text
) returns boolean
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_shop uuid;
begin
  select shop_id into v_shop from customers where id = p_customer_id;
  if not exists (select 1 from push_subscriptions where customer_id = p_customer_id) then
    return false;
  end if;
  insert into notification_queue (shop_id, customer_id, offer_id, kind, title, body, url)
  values (v_shop, p_customer_id, p_offer_id, p_kind, p_title, p_body, p_url);
  return true;
end $$;

-- ---------------------------------------------------------------------
-- Formatos de fecha en castellano
-- ---------------------------------------------------------------------
create function public._fmt_dia(p_at timestamptz, p_tz text) returns text
language sql stable set search_path = public, pg_temp as $$
  select (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
           [extract(dow from p_at at time zone p_tz)::int + 1]
         || ' ' || to_char(p_at at time zone p_tz, 'DD/MM')
$$;

create function public._fmt_hora(p_at timestamptz, p_tz text) returns text
language sql stable set search_path = public, pg_temp as $$
  select to_char(p_at at time zone p_tz, 'HH24:MI')
$$;

create function public._fmt_when(p_at timestamptz, p_tz text) returns text
language sql stable set search_path = public, pg_temp as $$
  select case when (p_at at time zone p_tz)::date = (now() at time zone p_tz)::date
              then 'hoy a las ' || public._fmt_hora(p_at, p_tz)
              else 'el ' || public._fmt_dia(p_at, p_tz) || ' a las ' || public._fmt_hora(p_at, p_tz) end
$$;

create function public._urlencode(p_text text) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare
  b bytea := convert_to(p_text, 'UTF8');
  r text := '';
  c int;
  i int;
begin
  for i in 0 .. length(b) - 1 loop
    c := get_byte(b, i);
    if (c between 48 and 57) or (c between 65 and 90) or (c between 97 and 122) or c in (45, 46, 95, 126) then
      r := r || chr(c);
    else
      r := r || '%' || upper(lpad(to_hex(c), 2, '0'));
    end if;
  end loop;
  return r;
end $$;

-- Aviso automático al peluquero (reservas, cambios y cancelaciones de clientes)
create function public._notify_admin() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor text := coalesce(nullif(current_setting('app.actor', true), ''), 'system');
  v_tz    text;
  v_name  text;
  v_title text;
  v_body  text;
begin
  if new.kind <> 'appointment' or v_actor = 'admin' then return null; end if;
  if not exists (select 1 from admin_push_subscriptions where shop_id = new.shop_id) then return null; end if;

  v_tz := (public._shop(new.shop_id)).timezone;
  select name into v_name from customers where id = new.customer_id;

  if tg_op = 'INSERT' then
    v_title := 'Nueva reserva';
    v_body  := format('%s · %s · %s %s', v_name, new.service_name,
                      public._fmt_dia(lower(new.period), v_tz), public._fmt_hora(lower(new.period), v_tz));
  elsif new.status = 'cancelled_by_customer' and old.status <> new.status then
    v_title := 'Turno cancelado';
    v_body  := format('%s canceló su turno del %s a las %s', v_name,
                      public._fmt_dia(lower(new.period), v_tz), public._fmt_hora(lower(new.period), v_tz));
  elsif new.period is distinct from old.period then
    v_title := 'Turno cambiado';
    v_body  := format('%s pasó del %s %s al %s %s', v_name,
                      public._fmt_dia(lower(old.period), v_tz), public._fmt_hora(lower(old.period), v_tz),
                      public._fmt_dia(lower(new.period), v_tz), public._fmt_hora(lower(new.period), v_tz));
  else
    return null;
  end if;

  insert into notification_queue (shop_id, to_admin, kind, title, body, url)
  values (new.shop_id, true, 'admin_' || lower(replace(v_title, ' ', '_')), v_title, v_body,
          '/admin/agenda?dia=' || ((lower(new.period) at time zone v_tz)::date)::text);
  return null;
end $$;

create trigger agenda_notify_admin after insert or update on public.agenda
  for each row execute function public._notify_admin();
