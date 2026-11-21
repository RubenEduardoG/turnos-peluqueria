-- =====================================================================
-- 04 · Funciones públicas (app de clientes)
--
-- Los clientes NO tienen cuenta ni acceso a tablas. Cada reserva devuelve
-- un enlace privado (token) que el celular guarda; en la base sólo se
-- guarda su huella SHA-256.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Información pública
-- ---------------------------------------------------------------------
create function public.info_negocio() returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'nombre',                     s.business_name,
    'whatsapp',                   s.whatsapp_phone,
    'reservas_habilitadas',       s.booking_enabled,
    'zona_horaria',               s.timezone,
    'dias_hacia_adelante',        s.max_booking_days_ahead,
    'permite_mismo_dia',          s.allow_same_day,
    'anticipacion_cancelar_min',  s.min_cancel_notice_minutes,
    'anticipacion_reprogramar_min', s.min_reschedule_notice_minutes,
    'lista_espera_activa',        s.offers_mode <> 'off'
  )
  from settings s where s.id
$$;

create function public.servicios_publicos()
returns table (id uuid, nombre text, descripcion text, precio numeric, duracion_min int)
language sql stable security definer set search_path = public, pg_temp as $$
  select id, name, description, price, duration_minutes
  from services where active
  order by sort_order, name
$$;

create function public.horarios_disponibles(p_service_id uuid, p_fecha date)
returns setof timestamptz
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if not (public._settings()).booking_enabled then return; end if;
  return query select * from public._horarios(p_service_id, p_fecha, null, true);
end $$;

-- Cantidad de horarios libres por día, para pintar el calendario.
create function public.dias_disponibles(p_service_id uuid, p_desde date, p_hasta date)
returns table (fecha date, horarios int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  d date;
begin
  if not (public._settings()).booking_enabled then return; end if;
  if p_hasta < p_desde or p_hasta - p_desde > 62 then
    raise exception 'RANGO_INVALIDO';
  end if;
  d := p_desde;
  while d <= p_hasta loop
    fecha    := d;
    horarios := (select count(*) from public._horarios(p_service_id, d, null, true));
    return next;
    d := d + 1;
  end loop;
end $$;

-- ---------------------------------------------------------------------
-- Reservar
-- ---------------------------------------------------------------------
create function public.reservar(
  p_service_id      uuid,
  p_inicio          timestamptz,
  p_nombre          text,
  p_telefono        text,
  p_email           text    default null,
  p_nota            text    default null,
  p_avisar_antes    boolean default false,
  p_acepta_privacidad boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s        public.settings := public._settings();
  svc      public.services;
  v_phone  text := public._normalize_phone(p_telefono);
  v_name   text := btrim(coalesce(p_nombre, ''));
  v_email  text := nullif(btrim(coalesce(p_email, '')), '');
  v_cust   public.customers;
  v_token  text := public._new_token();
  v_id     uuid;
  v_end    timestamptz;
  v_status text;
begin
  perform public._set_actor('customer');

  if not s.booking_enabled then raise exception 'RESERVAS_DESHABILITADAS'; end if;
  if not coalesce(p_acepta_privacidad, false) then raise exception 'FALTA_CONSENTIMIENTO'; end if;
  if length(v_name) not between 2 and 80 then raise exception 'NOMBRE_INVALIDO'; end if;
  if v_phone is null or v_phone !~ '^[0-9]{8,15}$' then raise exception 'TELEFONO_INVALIDO'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL_INVALIDO'; end if;
  if p_nota is not null and length(p_nota) > 500 then raise exception 'NOTA_DEMASIADO_LARGA'; end if;

  perform public._procesar_vencimientos();

  select * into svc from services where id = p_service_id and active;
  if not found then raise exception 'SERVICIO_NO_DISPONIBLE'; end if;

  if not exists (
    select 1 from public._horarios(p_service_id, (p_inicio at time zone s.timezone)::date, null, true) h
    where h = p_inicio
  ) then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end if;

  -- Cliente por teléfono (no se pisa el nombre de un cliente existente)
  insert into customers (name, phone, email) values (v_name, v_phone, v_email)
  on conflict (phone) do nothing;
  select * into v_cust from customers where phone = v_phone for update;

  if s.no_show_block_threshold is not null and (
       select count(*) from agenda where customer_id = v_cust.id and status = 'no_show'
     ) >= s.no_show_block_threshold then
    raise exception 'BLOQUEADO_POR_AUSENCIAS';
  end if;

  if s.max_active_appointments_per_phone is not null and (
       select count(*) from agenda
       where customer_id = v_cust.id and status in ('pending', 'confirmed') and upper(period) > now()
     ) >= s.max_active_appointments_per_phone then
    raise exception 'LIMITE_DE_TURNOS';
  end if;

  v_end    := p_inicio + make_interval(mins => svc.duration_minutes);
  v_status := case when s.auto_confirm then 'confirmed' else 'pending' end;

  begin
    insert into agenda (kind, status, period, buffer_minutes, customer_id, service_id, service_name,
                        price, duration_minutes, wants_earlier, customer_note, source, manage_token_hash)
    values ('appointment', v_status, tstzrange(p_inicio, v_end, '[)'), svc.buffer_minutes, v_cust.id,
            svc.id, svc.name, svc.price, svc.duration_minutes, coalesce(p_avisar_antes, false),
            nullif(btrim(coalesce(p_nota, '')), ''), 'online', public._hash(v_token))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end;

  return jsonb_build_object(
    'id', v_id, 'token', v_token, 'estado', v_status,
    'inicio', p_inicio, 'fin', v_end, 'servicio', svc.name, 'precio', svc.price
  );
end $$;

-- ---------------------------------------------------------------------
-- Mis turnos (el celular manda los enlaces que tiene guardados)
-- ---------------------------------------------------------------------
create function public.mis_turnos(p_tokens text[])
returns table (
  token text, id uuid, servicio text, precio numeric, inicio timestamptz, fin timestamptz,
  estado text, avisar_antes boolean, puede_cancelar boolean, puede_reprogramar boolean,
  oferta jsonb
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.settings := public._settings();
begin
  if coalesce(array_length(p_tokens, 1), 0) > 30 then raise exception 'DEMASIADOS_ENLACES'; end if;
  return query
    select t.tok, a.id, a.service_name, a.price, lower(a.period), upper(a.period), a.status,
           a.wants_earlier,
           a.status in ('pending', 'confirmed')
             and lower(a.period) - now() >= make_interval(mins => s.min_cancel_notice_minutes),
           a.status in ('pending', 'confirmed')
             and lower(a.period) - now() >= make_interval(mins => s.min_reschedule_notice_minutes),
           (select jsonb_build_object('tipo', o.kind, 'inicio_propuesto', lower(o.proposed_period),
                                      'vence', o.expires_at)
              from offers o
             where o.appointment_id = a.id and o.status = 'sent' and o.expires_at > now()
             limit 1)
      from unnest(p_tokens) as t(tok)
      join agenda a on a.manage_token_hash = public._hash(t.tok) and a.kind = 'appointment'
     order by lower(a.period);
end $$;

-- Busca el turno de un enlace (bloqueándolo para modificarlo)
create function public._appointment_by_token(p_token text) returns public.agenda
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  select * into a from agenda
   where manage_token_hash = public._hash(p_token) and kind = 'appointment'
   for update;
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  return a;
end $$;

create function public.cancelar_turno(p_token text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.settings := public._settings();
  a public.agenda;
begin
  perform public._set_actor('customer');
  a := public._appointment_by_token(p_token);
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if lower(a.period) - now() < make_interval(mins => s.min_cancel_notice_minutes) then
    raise exception 'FUERA_DE_PLAZO_CANCELACION';
  end if;

  update agenda set status = 'cancelled_by_customer', cancelled_at = now() where id = a.id;
  perform public._cancel_open_offers(a.id);
  perform public._on_slot_freed(lower(a.period), a.id);
  return jsonb_build_object('estado', 'cancelled_by_customer');
end $$;

-- Mueve un turno a otro horario disponible (misma lógica para cliente y oferta)
create function public._move_appointment(p_appointment public.agenda, p_new_start timestamptz, p_free_old boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s     public.settings := public._settings();
  v_new tstzrange;
begin
  if not exists (
    select 1 from public._horarios(p_appointment.service_id,
                                   (p_new_start at time zone s.timezone)::date, p_appointment.id, true) h
    where h = p_new_start
  ) then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end if;

  v_new := tstzrange(p_new_start, p_new_start + make_interval(mins => p_appointment.duration_minutes), '[)');
  perform public._cancel_open_offers(p_appointment.id);
  begin
    update agenda set period = v_new where id = p_appointment.id;
  exception when exclusion_violation then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end;
  if p_free_old then
    perform public._on_slot_freed(lower(p_appointment.period), p_appointment.id);
  end if;
  return jsonb_build_object('inicio', lower(v_new), 'fin', upper(v_new));
end $$;

create function public.reprogramar_turno(p_token text, p_nuevo_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.settings := public._settings();
  a public.agenda;
begin
  perform public._set_actor('customer');
  if not s.booking_enabled then raise exception 'RESERVAS_DESHABILITADAS'; end if;
  perform public._procesar_vencimientos();
  a := public._appointment_by_token(p_token);
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if lower(a.period) - now() < make_interval(mins => s.min_reschedule_notice_minutes) then
    raise exception 'FUERA_DE_PLAZO_REPROGRAMACION';
  end if;
  return public._move_appointment(a, p_nuevo_inicio, true);
end $$;

-- Horarios para mover MI turno (incluye los que se pisan con mi turno actual)
create function public.horarios_para_mi_turno(p_token text, p_fecha date) returns setof timestamptz
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  select * into a from agenda where manage_token_hash = public._hash(p_token) and kind = 'appointment';
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  return query select * from public._horarios(a.service_id, p_fecha, a.id, true);
end $$;

create function public.preferencia_adelanto(p_token text, p_activar boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  perform public._set_actor('customer');
  a := public._appointment_by_token(p_token);
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  update agenda set wants_earlier = coalesce(p_activar, false) where id = a.id;
  return jsonb_build_object('avisar_antes', coalesce(p_activar, false));
end $$;

-- ---------------------------------------------------------------------
-- Ofertas (adelanto o propuesta del peluquero)
-- ---------------------------------------------------------------------
create function public.ver_oferta(p_token text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'tipo', o.kind, 'estado', case when o.status = 'sent' and o.expires_at <= now() then 'expired' else o.status end,
    'servicio', a.service_name,
    'inicio_actual', lower(o.original_period), 'inicio_propuesto', lower(o.proposed_period),
    'fin_propuesto', upper(o.proposed_period), 'vence', o.expires_at
  )
  from offers o join agenda a on a.id = o.appointment_id
  where o.token_hash = public._hash(p_token)
$$;

create function public.responder_oferta(p_token text, p_acepta boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_id uuid;
begin
  perform public._set_actor('customer');
  select id into v_id from offers where token_hash = public._hash(p_token);
  if v_id is null then raise exception 'ENLACE_INVALIDO'; end if;
  return public._respond_offer(v_id, coalesce(p_acepta, false));
end $$;

-- Responder desde "Mis turnos" (con el enlace del turno, sin el de la oferta)
create function public.responder_oferta_de_mi_turno(p_token text, p_acepta boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a    public.agenda;
  v_id uuid;
begin
  perform public._set_actor('customer');
  select * into a from agenda where manage_token_hash = public._hash(p_token) and kind = 'appointment';
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  select id into v_id from offers where appointment_id = a.id and status = 'sent';
  if v_id is null then return jsonb_build_object('result', 'no_disponible'); end if;
  return public._respond_offer(v_id, coalesce(p_acepta, false));
end $$;

-- Ante una propuesta del peluquero, el cliente elige otro horario libre.
create function public.elegir_otro_horario(p_token_oferta text, p_nuevo_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o   public.offers;
  a   public.agenda;
  r   jsonb;
begin
  perform public._set_actor('customer');
  select * into o from offers where token_hash = public._hash(p_token_oferta) for update;
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  if o.kind <> 'proposal' or o.status <> 'sent' or o.expires_at <= now() then
    raise exception 'OFERTA_NO_DISPONIBLE';
  end if;
  select * into a from agenda where id = o.appointment_id for update;
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;

  -- _move_appointment cancela la propuesta abierta y libera su retención
  r := public._move_appointment(a, p_nuevo_inicio, false);
  update offers set status = 'declined' where id = o.id and status = 'cancelled';
  return r;
end $$;

-- ---------------------------------------------------------------------
-- Notificaciones push: el celular registra su suscripción
-- ---------------------------------------------------------------------
create function public.registrar_push(p_token text, p_endpoint text, p_p256dh text, p_auth text)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  select * into a from agenda where manage_token_hash = public._hash(p_token) and kind = 'appointment';
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or length(coalesce(p_p256dh, '')) not between 20 and 200
     or length(coalesce(p_auth, '')) not between 8 and 100 then
    raise exception 'SUSCRIPCION_INVALIDA';
  end if;
  insert into push_subscriptions (customer_id, endpoint, p256dh, auth)
  values (a.customer_id, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
    set customer_id = excluded.customer_id, p256dh = excluded.p256dh, auth = excluded.auth;
  return jsonb_build_object('ok', true);
end $$;
