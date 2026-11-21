-- =====================================================================
-- 05 · Funciones del panel del peluquero
-- Todas exigen ser el administrador (settings.owner_user_id = auth.uid()).
-- Las operaciones de varios pasos van por acá para que la agenda quede
-- siempre consistente; la lectura y la configuración simple van directo
-- a las tablas, protegidas por RLS.
-- =====================================================================

-- Datos para armar el mensaje de WhatsApp de un turno
create function public._whatsapp_info(p_appointment_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('turno_id', a.id, 'nombre', c.name, 'telefono', c.phone,
                            'servicio', a.service_name, 'inicio', lower(a.period))
  from agenda a join customers c on c.id = a.customer_id
  where a.id = p_appointment_id
$$;

create function public._upsert_customer_admin(p_nombre text, p_telefono text) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_phone text := public._normalize_phone(p_telefono);
  v_name  text := btrim(coalesce(p_nombre, ''));
  v_id    uuid;
begin
  if v_phone is null or v_phone !~ '^[0-9]{8,15}$' then raise exception 'TELEFONO_INVALIDO'; end if;
  if length(v_name) not between 2 and 80 then raise exception 'NOMBRE_INVALIDO'; end if;
  insert into customers (name, phone) values (v_name, v_phone)
  on conflict (phone) do update set name = excluded.name
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------
-- Turnos
-- ---------------------------------------------------------------------
create function public.admin_crear_turno(
  p_nombre text, p_telefono text, p_service_id uuid, p_inicio timestamptz,
  p_nota text default null, p_fuera_de_horario boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  svc     public.services;
  v_cust  uuid;
  v_token text := public._new_token();
  v_per   tstzrange;
  v_id    uuid;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  select * into svc from services where id = p_service_id;
  if not found then raise exception 'SERVICIO_NO_DISPONIBLE'; end if;

  v_per := tstzrange(p_inicio, p_inicio + make_interval(mins => svc.duration_minutes), '[)');
  if not p_fuera_de_horario and not public._within_hours(v_per) then
    raise exception 'FUERA_DE_HORARIO';
  end if;
  v_cust := public._upsert_customer_admin(p_nombre, p_telefono);

  begin
    insert into agenda (kind, status, period, buffer_minutes, customer_id, service_id, service_name,
                        price, duration_minutes, admin_note, source, manage_token_hash)
    values ('appointment', 'confirmed', v_per, svc.buffer_minutes, v_cust, svc.id, svc.name,
            svc.price, svc.duration_minutes, nullif(btrim(coalesce(p_nota, '')), ''), 'admin',
            public._hash(v_token))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'HORARIO_OCUPADO';
  end;
  return public._whatsapp_info(v_id) || jsonb_build_object('token', v_token);
end $$;

create function public.admin_cancelar_turno(
  p_turno_id uuid, p_motivo text default null, p_ofrecer_hueco boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  select * into a from agenda where id = p_turno_id and kind = 'appointment' for update;
  if not found then raise exception 'TURNO_INEXISTENTE'; end if;
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;

  update agenda set status = 'cancelled_by_admin', cancelled_at = now(), reason = p_motivo where id = a.id;
  perform public._cancel_open_offers(a.id);
  if p_ofrecer_hueco then perform public._on_slot_freed(lower(a.period), a.id); end if;
  return public._whatsapp_info(a.id);
end $$;

-- Mover un turno directamente (ya acordado con el cliente)
create function public.admin_reprogramar_turno(
  p_turno_id uuid, p_nuevo_inicio timestamptz,
  p_fuera_de_horario boolean default false, p_ofrecer_hueco boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a     public.agenda;
  v_new tstzrange;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  select * into a from agenda where id = p_turno_id and kind = 'appointment' for update;
  if not found then raise exception 'TURNO_INEXISTENTE'; end if;
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;

  v_new := tstzrange(p_nuevo_inicio, p_nuevo_inicio + make_interval(mins => a.duration_minutes), '[)');
  if not p_fuera_de_horario and not public._within_hours(v_new) then raise exception 'FUERA_DE_HORARIO'; end if;

  perform public._cancel_open_offers(a.id);
  begin
    update agenda set period = v_new where id = a.id;
  exception when exclusion_violation then
    raise exception 'HORARIO_OCUPADO';
  end;
  if p_ofrecer_hueco then perform public._on_slot_freed(lower(a.period), a.id); end if;
  return public._whatsapp_info(a.id);
end $$;

-- Proponer otro horario: el turno original sigue en pie hasta que el cliente acepte.
-- Devuelve el enlace de la propuesta para mandarlo por WhatsApp.
create function public.admin_proponer_horario(
  p_turno_id uuid, p_nuevo_inicio timestamptz, p_fuera_de_horario boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s        public.settings := public._settings();
  a        public.agenda;
  v_new    tstzrange;
  v_occ    tstzrange;
  v_hold   tstzrange;
  v_hold_id uuid;
  v_offer  uuid;
  v_token  text;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  select * into a from agenda where id = p_turno_id and kind = 'appointment' for update;
  if not found then raise exception 'TURNO_INEXISTENTE'; end if;
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;

  v_new := tstzrange(p_nuevo_inicio, p_nuevo_inicio + make_interval(mins => a.duration_minutes), '[)');
  v_occ := tstzrange(p_nuevo_inicio, upper(v_new) + make_interval(mins => a.buffer_minutes), '[)');
  if p_nuevo_inicio - make_interval(mins => s.offer_min_lead_minutes) <= now() then
    raise exception 'HORARIO_MUY_CERCANO';
  end if;
  if not p_fuera_de_horario and not public._within_hours(v_new) then raise exception 'FUERA_DE_HORARIO'; end if;
  if public._overlaps(v_occ, a.id) then raise exception 'HORARIO_OCUPADO'; end if;

  perform public._cancel_open_offers(a.id);

  -- Retener el tramo propuesto que no se pisa con el turno actual
  if v_occ && a.occupied then
    if lower(v_occ) < lower(a.occupied) then
      v_hold := tstzrange(lower(v_occ), lower(a.occupied), '[)');
    elsif upper(v_occ) > upper(a.occupied) then
      v_hold := tstzrange(upper(a.occupied), upper(v_occ), '[)');
    end if;  -- si queda contenido en el turno actual, no hace falta retener
  else
    v_hold := v_occ;
  end if;

  if v_hold is not null and not isempty(v_hold) then
    begin
      insert into agenda (kind, status, period, hold_expires_at, reason)
      values ('hold', 'active', v_hold, now() + interval '1 hour', 'Propuesta de cambio')
      returning id into v_hold_id;
    exception when exclusion_violation then
      raise exception 'HORARIO_OCUPADO';
    end;
  end if;

  insert into offers (kind, appointment_id, original_period, proposed_period, hold_id, status, expires_at)
  values ('proposal', a.id, a.period, v_new, v_hold_id, 'pending_approval', now() + interval '1 hour')
  returning id into v_offer;

  v_token := public._send_offer(v_offer);
  return public._whatsapp_info(a.id)
         || jsonb_build_object('oferta_id', v_offer, 'token_oferta', v_token,
                               'inicio_propuesto', p_nuevo_inicio,
                               'vence', (select expires_at from offers where id = v_offer));
end $$;

create function public.admin_marcar_turno(p_turno_id uuid, p_estado text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  if p_estado not in ('confirmed', 'completed', 'no_show') then raise exception 'ESTADO_INVALIDO'; end if;
  select * into a from agenda where id = p_turno_id and kind = 'appointment' for update;
  if not found then raise exception 'TURNO_INEXISTENTE'; end if;

  if p_estado = 'confirmed' and a.status <> 'pending' then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if p_estado in ('completed', 'no_show') then
    if a.status not in ('pending', 'confirmed', 'completed', 'no_show') then
      raise exception 'TURNO_NO_MODIFICABLE';
    end if;
    if lower(a.period) > now() then raise exception 'TURNO_AUN_NO_EMPEZO'; end if;
  end if;

  if p_estado <> 'confirmed' then perform public._cancel_open_offers(a.id); end if;
  update agenda set status = p_estado where id = a.id;
  return jsonb_build_object('estado', p_estado);
end $$;

-- Nuevo enlace privado para reenviar al cliente (invalida el anterior)
create function public.admin_enlace_turno(p_turno_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_token text := public._new_token();
begin
  perform public._require_admin();
  update agenda set manage_token_hash = public._hash(v_token)
   where id = p_turno_id and kind = 'appointment';
  if not found then raise exception 'TURNO_INEXISTENTE'; end if;
  return public._whatsapp_info(p_turno_id) || jsonb_build_object('token', v_token);
end $$;

-- ---------------------------------------------------------------------
-- Bloqueos (horas, días, vacaciones, resto de la jornada)
-- ---------------------------------------------------------------------
create function public.admin_bloquear(
  p_desde timestamptz, p_hasta timestamptz, p_motivo text default null,
  p_cancelar_turnos boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_range     tstzrange;
  v_conflicts jsonb;
  r           record;
  v_id        uuid;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  if p_hasta <= p_desde then raise exception 'RANGO_INVALIDO'; end if;
  v_range := tstzrange(p_desde, p_hasta, '[)');

  select coalesce(jsonb_agg(public._whatsapp_info(a.id) order by lower(a.period)), '[]'::jsonb)
    into v_conflicts
    from agenda a
   where a.kind = 'appointment' and a.status in ('pending', 'confirmed') and a.occupied && v_range;

  if jsonb_array_length(v_conflicts) > 0 and not p_cancelar_turnos then
    raise exception 'HAY_TURNOS_EN_CONFLICTO' using detail = v_conflicts::text;
  end if;

  for r in
    select id from agenda
     where kind = 'appointment' and status in ('pending', 'confirmed') and occupied && v_range
     for update
  loop
    update agenda set status = 'cancelled_by_admin', cancelled_at = now(), reason = p_motivo where id = r.id;
    perform public._cancel_open_offers(r.id);
  end loop;

  -- Retenciones de ofertas que caen en el bloqueo
  for r in
    select o.id, o.hold_id from offers o join agenda h on h.id = o.hold_id
     where o.status in ('pending_approval', 'sent') and h.status = 'active' and h.occupied && v_range
     for update of o
  loop
    perform public._release_hold(r.hold_id);
    update offers set status = 'cancelled', responded_at = now() where id = r.id;
  end loop;
  update agenda set status = 'released' where kind = 'hold' and status = 'active' and occupied && v_range;

  begin
    insert into agenda (kind, status, period, reason)
    values ('block', 'active', v_range, nullif(btrim(coalesce(p_motivo, '')), ''))
    returning id into v_id;
  exception when exclusion_violation then
    -- se superpone con turnos ya realizados/ausentes o con otro bloqueo
    raise exception 'RANGO_SUPERPUESTO';
  end;

  return jsonb_build_object('bloqueo_id', v_id, 'turnos_cancelados', v_conflicts);
end $$;

-- "Bloquear el resto de la jornada": desde ahora (o la hora indicada) hasta medianoche
create function public.admin_bloquear_resto_jornada(
  p_desde timestamptz default now(), p_motivo text default null, p_cancelar_turnos boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_tz  text := (public._settings()).timezone;
  v_fin timestamptz := (((p_desde at time zone v_tz)::date + 1)::timestamp) at time zone v_tz;
begin
  return public.admin_bloquear(p_desde, v_fin, p_motivo, p_cancelar_turnos);
end $$;

-- Bloquear días completos o vacaciones (fechas locales, ambas incluidas)
create function public.admin_bloquear_dias(
  p_desde date, p_hasta date, p_motivo text default null, p_cancelar_turnos boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_tz text := (public._settings()).timezone;
begin
  if p_hasta < p_desde then raise exception 'RANGO_INVALIDO'; end if;
  return public.admin_bloquear(p_desde::timestamp at time zone v_tz,
                               (p_hasta + 1)::timestamp at time zone v_tz,
                               p_motivo, p_cancelar_turnos);
end $$;

create function public.admin_quitar_bloqueo(p_bloqueo_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  update agenda set status = 'released' where id = p_bloqueo_id and kind = 'block' and status = 'active';
  if not found then raise exception 'BLOQUEO_INEXISTENTE'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Lista de espera desde el panel
-- ---------------------------------------------------------------------
create function public.admin_ofrecer_hueco(p_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_offer uuid;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  v_offer := public._on_slot_freed(p_inicio, null);
  return jsonb_build_object('oferta_id', v_offer);
end $$;

-- Aprobar (y enviar) una oferta pendiente. Devuelve el enlace para WhatsApp.
create function public.admin_aprobar_oferta(p_oferta_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s       public.settings := public._settings();
  o       public.offers;
  v_token text;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  select * into o from offers where id = p_oferta_id for update;
  if not found or o.status <> 'pending_approval' then raise exception 'OFERTA_NO_DISPONIBLE'; end if;
  if o.expires_at <= now() then raise exception 'OFERTA_VENCIDA'; end if;
  v_token := public._send_offer(o.id);
  return public._whatsapp_info(o.appointment_id)
         || jsonb_build_object('oferta_id', o.id, 'tipo', o.kind, 'token_oferta', v_token,
                               'inicio_propuesto', lower(o.proposed_period),
                               'vence', (select expires_at from offers where id = o.id));
end $$;

-- Descartar una oferta pendiente y pasar al siguiente candidato
create function public.admin_descartar_oferta(p_oferta_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o      public.offers;
  v_next uuid;
begin
  perform public._require_admin();
  perform public._set_actor('admin');
  select * into o from offers where id = p_oferta_id for update;
  if not found or o.status not in ('pending_approval', 'sent') then raise exception 'OFERTA_NO_DISPONIBLE'; end if;
  perform public._release_hold(o.hold_id);
  update offers set status = 'cancelled', responded_at = now() where id = o.id;
  if o.kind = 'advance' then v_next := public._offer_next(o.freed_slot_id); end if;
  return jsonb_build_object('siguiente_oferta_id', v_next);
end $$;

-- Nuevo enlace para una oferta ya enviada (para mandarla por WhatsApp)
create function public.admin_enlace_oferta(p_oferta_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o       public.offers;
  v_token text := public._new_token();
begin
  perform public._require_admin();
  select * into o from offers where id = p_oferta_id and status = 'sent' for update;
  if not found then raise exception 'OFERTA_NO_DISPONIBLE'; end if;
  update offers set token_hash = public._hash(v_token) where id = o.id;
  return public._whatsapp_info(o.appointment_id)
         || jsonb_build_object('oferta_id', o.id, 'tipo', o.kind, 'token_oferta', v_token,
                               'inicio_propuesto', lower(o.proposed_period), 'vence', o.expires_at);
end $$;

-- ---------------------------------------------------------------------
-- Estadísticas
-- ---------------------------------------------------------------------
create function public.admin_estadisticas(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_tz  text := (public._settings()).timezone;
  v_ini timestamptz := p_desde::timestamp at time zone v_tz;
  v_fin timestamptz := (p_hasta + 1)::timestamp at time zone v_tz;
  r     jsonb;
begin
  perform public._require_admin();
  with t as (
    select a.*, (lower(a.period) at time zone v_tz)::date as dia
      from agenda a
     where a.kind = 'appointment' and lower(a.period) >= v_ini and lower(a.period) < v_fin
  )
  select jsonb_build_object(
    'total',            (select count(*) from t),
    'por_estado',       coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from t group by status) x), '{}'),
    'por_dia',          coalesce((select jsonb_agg(jsonb_build_object('dia', dia, 'turnos', n) order by dia)
                                    from (select dia, count(*) n from t
                                           where status not in ('cancelled_by_customer', 'cancelled_by_admin')
                                           group by dia) x), '[]'),
    'por_mes',          coalesce((select jsonb_agg(jsonb_build_object('mes', mes, 'turnos', n) order by mes)
                                    from (select to_char(dia, 'YYYY-MM') mes, count(*) n from t
                                           where status not in ('cancelled_by_customer', 'cancelled_by_admin')
                                           group by 1) x), '[]'),
    'servicios_mas_pedidos', coalesce((select jsonb_agg(jsonb_build_object('servicio', service_name, 'turnos', n) order by n desc)
                                    from (select service_name, count(*) n from t
                                           where status not in ('cancelled_by_customer', 'cancelled_by_admin')
                                           group by service_name) x), '[]'),
    'ingresos_estimados', coalesce((select sum(price) from t where status = 'completed'), 0),
    'cobros_por_medio', coalesce((select jsonb_object_agg(method, total)
                                    from (select method, sum(amount) total from payments
                                           where paid_at >= v_ini and paid_at < v_fin group by method) x), '{}'),
    'clientes_ausentes', coalesce((select jsonb_agg(jsonb_build_object('nombre', c.name, 'telefono', c.phone, 'ausencias', n) order by n desc)
                                    from (select customer_id, count(*) n from t where status = 'no_show' group by customer_id) x
                                    join customers c on c.id = x.customer_id), '[]')
  ) into r;
  return r;
end $$;
