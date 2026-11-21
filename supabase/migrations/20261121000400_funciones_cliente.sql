-- =====================================================================
-- 04 · Funciones públicas (app de clientes)
--
-- La peluquería se identifica por su dirección (slug): tuapp/<slug>.
-- Los clientes NO tienen cuenta: cada reserva devuelve un enlace privado
-- (token) que el celular guarda; en la base sólo se guarda su huella.
-- =====================================================================

create function public.info_negocio(p_slug text) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._shop_by_slug(p_slug);
begin
  if s.status = 'pending' then raise exception 'PELUQUERIA_INEXISTENTE'; end if;
  return jsonb_build_object(
    'slug',                         s.slug,
    'nombre',                       s.business_name,
    'direccion',                    s.address,
    'whatsapp',                     s.whatsapp_phone,
    'reservas_habilitadas',         public._shop_open(s),
    'zona_horaria',                 s.timezone,
    'dias_hacia_adelante',          s.max_booking_days_ahead,
    'permite_mismo_dia',            s.allow_same_day,
    'anticipacion_cancelar_min',    s.min_cancel_notice_minutes,
    'anticipacion_reprogramar_min', s.min_reschedule_notice_minutes,
    'lista_espera_activa',          s.offers_mode <> 'off'
  );
end $$;

create function public.servicios_publicos(p_slug text)
returns table (id uuid, nombre text, descripcion text, precio numeric, duracion_min int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._shop_by_slug(p_slug);
begin
  if not public._shop_open(s) then return; end if;
  return query
    select sv.id, sv.name, sv.description, sv.price, sv.duration_minutes
      from services sv where sv.shop_id = s.id and sv.active
     order by sv.sort_order, sv.name;
end $$;

create function public.horarios_disponibles(p_slug text, p_service_id uuid, p_fecha date)
returns setof timestamptz
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._shop_by_slug(p_slug);
begin
  if not public._shop_open(s) then return; end if;
  if not exists (select 1 from services where id = p_service_id and shop_id = s.id) then return; end if;
  return query select * from public._horarios(p_service_id, p_fecha, null, true);
end $$;

create function public.dias_disponibles(p_slug text, p_service_id uuid, p_desde date, p_hasta date)
returns table (fecha date, horarios int)
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._shop_by_slug(p_slug);
  d date;
begin
  if p_hasta < p_desde or p_hasta - p_desde > 62 then raise exception 'RANGO_INVALIDO'; end if;
  if not public._shop_open(s) or not exists (select 1 from services where id = p_service_id and shop_id = s.id) then
    return;
  end if;
  d := p_desde;
  while d <= p_hasta loop
    fecha    := d;
    horarios := (select count(*) from public._horarios(p_service_id, d, null, true));
    return next;
    d := d + 1;
  end loop;
end $$;

create function public.reservar(
  p_slug              text,
  p_service_id        uuid,
  p_inicio            timestamptz,
  p_nombre            text,
  p_telefono          text,
  p_email             text    default null,
  p_nota              text    default null,
  p_acepta_privacidad boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s        public.shops := public._shop_by_slug(p_slug);
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

  if not public._shop_open(s) then raise exception 'RESERVAS_DESHABILITADAS'; end if;
  if not coalesce(p_acepta_privacidad, false) then raise exception 'FALTA_CONSENTIMIENTO'; end if;
  if length(v_name) not between 2 and 80 then raise exception 'NOMBRE_INVALIDO'; end if;
  if v_phone is null or v_phone !~ '^[0-9]{8,15}$' then raise exception 'TELEFONO_INVALIDO'; end if;
  if v_email is not null and v_email !~* '^[^@\s]+@[^@\s]+\.[^@\s]+$' then raise exception 'EMAIL_INVALIDO'; end if;
  if p_nota is not null and length(p_nota) > 500 then raise exception 'NOTA_DEMASIADO_LARGA'; end if;

  perform public._procesar_vencimientos();

  select * into svc from services where id = p_service_id and shop_id = s.id and active;
  if not found then raise exception 'SERVICIO_NO_DISPONIBLE'; end if;

  if not exists (
    select 1 from public._horarios(svc.id, (p_inicio at time zone s.timezone)::date, null, true) h
    where h = p_inicio
  ) then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end if;

  insert into customers (shop_id, name, phone, email) values (s.id, v_name, v_phone, v_email)
  on conflict (shop_id, phone) do nothing;
  select * into v_cust from customers where shop_id = s.id and phone = v_phone for update;

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
    insert into agenda (shop_id, kind, status, period, buffer_minutes, customer_id, service_id, service_name,
                        price, duration_minutes, customer_note, source, manage_token_hash)
    values (s.id, 'appointment', v_status, tstzrange(p_inicio, v_end, '[)'), svc.buffer_minutes, v_cust.id,
            svc.id, svc.name, svc.price, svc.duration_minutes,
            nullif(btrim(coalesce(p_nota, '')), ''), 'online', public._hash(v_token))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'HORARIO_NO_DISPONIBLE';
  end;

  return jsonb_build_object(
    'id', v_id, 'token', v_token, 'estado', v_status, 'slug', s.slug,
    'inicio', p_inicio, 'fin', v_end, 'servicio', svc.name, 'precio', svc.price
  );
end $$;

-- Mis turnos: el celular manda los enlaces que tiene guardados (de una o varias peluquerías)
create function public.mis_turnos(p_tokens text[])
returns table (
  token text, slug text, peluqueria text, id uuid, servicio text, precio numeric,
  inicio timestamptz, fin timestamptz, estado text, avisar_antes boolean,
  puede_cancelar boolean, puede_reprogramar boolean, debe_elegir_horario boolean, oferta jsonb
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  if coalesce(array_length(p_tokens, 1), 0) > 30 then raise exception 'DEMASIADOS_ENLACES'; end if;
  return query
    select t.tok, s.slug, s.business_name, a.id, a.service_name, a.price, lower(a.period), upper(a.period),
           a.status, a.wants_earlier,
           a.status in ('pending', 'confirmed')
             and lower(a.period) - now() >= make_interval(mins => s.min_cancel_notice_minutes),
           (a.status in ('pending', 'confirmed')
             and lower(a.period) - now() >= make_interval(mins => s.min_reschedule_notice_minutes))
             or (a.status = 'cancelled_by_admin' and a.can_rebook),
           a.status = 'cancelled_by_admin' and a.can_rebook,
           (select jsonb_build_object('tipo', o.kind, 'inicio_propuesto', lower(o.proposed_period),
                                      'vence', o.expires_at)
              from offers o
             where o.appointment_id = a.id and o.status = 'sent' and o.expires_at > now()
             limit 1)
      from unnest(p_tokens) as t(tok)
      join agenda a on a.manage_token_hash = public._hash(t.tok) and a.kind = 'appointment'
      join shops s on s.id = a.shop_id
     order by lower(a.period);
end $$;

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
  a public.agenda := public._appointment_by_token(p_token);
  s public.shops  := public._shop(a.shop_id);
begin
  perform public._set_actor('customer');
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if lower(a.period) - now() < make_interval(mins => s.min_cancel_notice_minutes) then
    raise exception 'FUERA_DE_PLAZO_CANCELACION';
  end if;

  update agenda set status = 'cancelled_by_customer', cancelled_at = now() where id = a.id;
  perform public._cancel_open_offers(a.id);
  perform public._on_slot_freed(a.shop_id, lower(a.period), a.id);
  return jsonb_build_object('estado', 'cancelled_by_customer');
end $$;

create function public._move_appointment(p_appointment public.agenda, p_new_start timestamptz, p_free_old boolean)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s     public.shops := public._shop(p_appointment.shop_id);
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
    perform public._on_slot_freed(p_appointment.shop_id, lower(p_appointment.period), p_appointment.id);
  end if;
  return jsonb_build_object('inicio', lower(v_new), 'fin', upper(v_new));
end $$;

-- El cliente cambia su horario solo. También sirve para turnos que el
-- peluquero suspendió con la opción "que el cliente elija otro horario".
create function public.reprogramar_turno(p_token text, p_nuevo_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda := public._appointment_by_token(p_token);
  s public.shops  := public._shop(a.shop_id);
begin
  perform public._set_actor('customer');
  if not public._shop_open(s) then raise exception 'RESERVAS_DESHABILITADAS'; end if;
  perform public._procesar_vencimientos();

  if a.status = 'cancelled_by_admin' and a.can_rebook then
    if not exists (
      select 1 from public._horarios(a.service_id, (p_nuevo_inicio at time zone s.timezone)::date, a.id, true) h
      where h = p_nuevo_inicio
    ) then
      raise exception 'HORARIO_NO_DISPONIBLE';
    end if;
    begin
      update agenda
         set period = tstzrange(p_nuevo_inicio, p_nuevo_inicio + make_interval(mins => a.duration_minutes), '[)'),
             status = 'confirmed', can_rebook = false, cancelled_at = null, reason = null
       where id = a.id;
    exception when exclusion_violation then
      raise exception 'HORARIO_NO_DISPONIBLE';
    end;
    return jsonb_build_object('inicio', p_nuevo_inicio,
                              'fin', p_nuevo_inicio + make_interval(mins => a.duration_minutes));
  end if;

  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if lower(a.period) - now() < make_interval(mins => s.min_reschedule_notice_minutes) then
    raise exception 'FUERA_DE_PLAZO_REPROGRAMACION';
  end if;
  return public._move_appointment(a, p_nuevo_inicio, true);
end $$;

create function public.horarios_para_mi_turno(p_token text, p_fecha date) returns setof timestamptz
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  select * into a from agenda where manage_token_hash = public._hash(p_token) and kind = 'appointment';
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  if not public._shop_open(public._shop(a.shop_id)) then return; end if;
  return query select * from public._horarios(a.service_id, p_fecha, a.id, true);
end $$;

-- "Avisarme si se libera antes" requiere notificaciones activadas
create function public.preferencia_adelanto(p_token text, p_activar boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda := public._appointment_by_token(p_token);
begin
  perform public._set_actor('customer');
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if coalesce(p_activar, false)
     and not exists (select 1 from push_subscriptions where customer_id = a.customer_id) then
    raise exception 'NECESITA_NOTIFICACIONES';
  end if;
  update agenda set wants_earlier = coalesce(p_activar, false) where id = a.id;
  return jsonb_build_object('avisar_antes', coalesce(p_activar, false));
end $$;

create function public.ver_oferta(p_token text) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'tipo', o.kind,
    'estado', case when o.status = 'sent' and o.expires_at <= now() then 'expired' else o.status end,
    'peluqueria', s.business_name, 'slug', s.slug, 'servicio', a.service_name,
    'inicio_actual', lower(o.original_period), 'inicio_propuesto', lower(o.proposed_period),
    'fin_propuesto', upper(o.proposed_period), 'vence', o.expires_at
  )
  from offers o join agenda a on a.id = o.appointment_id join shops s on s.id = o.shop_id
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

create function public.elegir_otro_horario(p_token_oferta text, p_nuevo_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o public.offers;
  a public.agenda;
  r jsonb;
begin
  perform public._set_actor('customer');
  select * into o from offers where token_hash = public._hash(p_token_oferta) for update;
  if not found then raise exception 'ENLACE_INVALIDO'; end if;
  if o.kind <> 'proposal' or o.status <> 'sent' or o.expires_at <= now() then
    raise exception 'OFERTA_NO_DISPONIBLE';
  end if;
  select * into a from agenda where id = o.appointment_id for update;
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  r := public._move_appointment(a, p_nuevo_inicio, false);
  update offers set status = 'declined' where id = o.id and status = 'cancelled';
  return r;
end $$;

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
  insert into push_subscriptions (shop_id, customer_id, endpoint, p256dh, auth)
  values (a.shop_id, a.customer_id, p_endpoint, p_p256dh, p_auth)
  on conflict (shop_id, endpoint) do update
    set customer_id = excluded.customer_id, p256dh = excluded.p256dh, auth = excluded.auth;
  return jsonb_build_object('ok', true);
end $$;
