-- =====================================================================
-- 05 · Funciones del panel del peluquero
-- Cada función toma la peluquería del usuario logueado (_require_admin) y
-- sólo toca filas de esa peluquería.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Registro: el peluquero crea su cuenta (Supabase Auth) y después su
-- peluquería, que queda PENDIENTE hasta que la plataforma la active.
-- ---------------------------------------------------------------------
create function public.registrar_peluqueria(p_slug text, p_nombre text, p_whatsapp text default null)
returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_slug text := lower(btrim(coalesce(p_slug, '')));
  v_id   uuid;
begin
  if auth.uid() is null then raise exception 'NO_AUTORIZADO' using errcode = '42501'; end if;
  if exists (select 1 from shops where owner_user_id = auth.uid()) then raise exception 'YA_TENES_PELUQUERIA'; end if;
  if v_slug !~ '^[a-z0-9](?:[a-z0-9-]{1,38}[a-z0-9])$' then raise exception 'DIRECCION_INVALIDA'; end if;
  if exists (select 1 from shops where slug = v_slug) then raise exception 'DIRECCION_EN_USO'; end if;
  if length(btrim(coalesce(p_nombre, ''))) not between 2 and 80 then raise exception 'NOMBRE_INVALIDO'; end if;

  insert into shops (slug, owner_user_id, business_name, whatsapp_phone)
  values (v_slug, auth.uid(), btrim(p_nombre), public._normalize_phone(p_whatsapp))
  returning id into v_id;

  insert into message_templates (shop_id, title, body, sort_order) values
    (v_id, 'Imprevisto',
     'Hola {nombre}, ¿cómo estás? Te escribo porque por un imprevisto no voy a poder atenderte el {dia} a las {hora}. Disculpá las molestias. {enlace}', 1),
    (v_id, 'Problema de salud',
     'Hola {nombre}, ¿cómo estás? Por un problema de salud no voy a poder atenderte el {dia} a las {hora}. Perdón por avisarte sobre la hora. {enlace}', 2),
    (v_id, 'Problema en el local',
     'Hola {nombre}, ¿cómo estás? Tuvimos un problema en el local y no vamos a poder atenderte el {dia} a las {hora}. Disculpá las molestias. {enlace}', 3),
    (v_id, 'Cambio de agenda',
     'Hola {nombre}, ¿cómo estás? Necesito modificar mi agenda y tu turno del {dia} a las {hora} queda suspendido. {enlace}', 4),
    (v_id, 'Mensaje del documento',
     'Hola, ¿cómo estás? Te escribimos para avisarte que por un imprevisto necesitamos modificar tu turno del {dia} a las {hora}. Disculpá las molestias. {enlace}', 5);

  return jsonb_build_object('id', v_id, 'slug', v_slug, 'estado', 'pending');
end $$;

-- Estado de mi peluquería (para mostrar "pendiente de aprobación" o "vence el…")
create function public.mi_peluqueria() returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s public.shops;
begin
  select * into s from shops where owner_user_id = auth.uid();
  if not found then return null; end if;
  return to_jsonb(s) - 'owner_user_id'
         || jsonb_build_object('activa', public._shop_active(s), 'abierta_al_publico', public._shop_open(s));
end $$;

-- ---------------------------------------------------------------------
-- Utilidades
-- ---------------------------------------------------------------------
create function public._whatsapp_info(p_appointment_id uuid) returns jsonb
language sql stable security definer set search_path = public, pg_temp as $$
  select jsonb_build_object('turno_id', a.id, 'nombre', c.name, 'telefono', c.phone,
                            'servicio', a.service_name, 'inicio', lower(a.period))
  from agenda a join customers c on c.id = a.customer_id
  where a.id = p_appointment_id
$$;

create function public._upsert_customer_admin(p_shop_id uuid, p_nombre text, p_telefono text) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  v_phone text := public._normalize_phone(p_telefono);
  v_name  text := btrim(coalesce(p_nombre, ''));
  v_id    uuid;
begin
  if v_phone is null or v_phone !~ '^[0-9]{8,15}$' then raise exception 'TELEFONO_INVALIDO'; end if;
  if length(v_name) not between 2 and 80 then raise exception 'NOMBRE_INVALIDO'; end if;
  insert into customers (shop_id, name, phone) values (p_shop_id, v_name, v_phone)
  on conflict (shop_id, phone) do update set name = excluded.name
  returning id into v_id;
  return v_id;
end $$;

create function public._my_appointment(p_shop_id uuid, p_turno_id uuid) returns public.agenda
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  select * into a from agenda
   where id = p_turno_id and shop_id = p_shop_id and kind = 'appointment' for update;
  if not found then raise exception 'TURNO_INEXISTENTE'; end if;
  return a;
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
  s       public.shops := public._require_admin();
  svc     public.services;
  v_cust  uuid;
  v_token text := public._new_token();
  v_per   tstzrange;
  v_id    uuid;
begin
  perform public._set_actor('admin');
  select * into svc from services where id = p_service_id and shop_id = s.id;
  if not found then raise exception 'SERVICIO_NO_DISPONIBLE'; end if;

  v_per := tstzrange(p_inicio, p_inicio + make_interval(mins => svc.duration_minutes), '[)');
  if not p_fuera_de_horario and not public._within_hours(s.id, v_per) then raise exception 'FUERA_DE_HORARIO'; end if;
  v_cust := public._upsert_customer_admin(s.id, p_nombre, p_telefono);

  begin
    insert into agenda (shop_id, kind, status, period, buffer_minutes, customer_id, service_id, service_name,
                        price, duration_minutes, admin_note, source, manage_token_hash)
    values (s.id, 'appointment', 'confirmed', v_per, svc.buffer_minutes, v_cust, svc.id, svc.name,
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
  s public.shops := public._require_admin();
  a public.agenda := public._my_appointment(s.id, p_turno_id);
begin
  perform public._set_actor('admin');
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  update agenda set status = 'cancelled_by_admin', cancelled_at = now(), reason = p_motivo where id = a.id;
  perform public._cancel_open_offers(a.id);
  if p_ofrecer_hueco then perform public._on_slot_freed(s.id, lower(a.period), a.id); end if;
  return public._whatsapp_info(a.id);
end $$;

create function public.admin_reprogramar_turno(
  p_turno_id uuid, p_nuevo_inicio timestamptz,
  p_fuera_de_horario boolean default false, p_ofrecer_hueco boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s     public.shops := public._require_admin();
  a     public.agenda := public._my_appointment(s.id, p_turno_id);
  v_new tstzrange;
begin
  perform public._set_actor('admin');
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  v_new := tstzrange(p_nuevo_inicio, p_nuevo_inicio + make_interval(mins => a.duration_minutes), '[)');
  if not p_fuera_de_horario and not public._within_hours(s.id, v_new) then raise exception 'FUERA_DE_HORARIO'; end if;

  perform public._cancel_open_offers(a.id);
  begin
    update agenda set period = v_new where id = a.id;
  exception when exclusion_violation then
    raise exception 'HORARIO_OCUPADO';
  end;
  if p_ofrecer_hueco then perform public._on_slot_freed(s.id, lower(a.period), a.id); end if;
  return public._whatsapp_info(a.id);
end $$;

-- Proponer otro horario: el turno original sigue en pie hasta que el cliente acepte.
create function public.admin_proponer_horario(
  p_turno_id uuid, p_nuevo_inicio timestamptz, p_fuera_de_horario boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s         public.shops := public._require_admin();
  a         public.agenda := public._my_appointment(s.id, p_turno_id);
  v_new     tstzrange;
  v_occ     tstzrange;
  v_hold    tstzrange;
  v_hold_id uuid;
  v_offer   uuid;
  v_token   text;
begin
  perform public._set_actor('admin');
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;

  v_new := tstzrange(p_nuevo_inicio, p_nuevo_inicio + make_interval(mins => a.duration_minutes), '[)');
  v_occ := tstzrange(p_nuevo_inicio, upper(v_new) + make_interval(mins => a.buffer_minutes), '[)');
  if p_nuevo_inicio - make_interval(mins => s.offer_min_lead_minutes) <= now() then raise exception 'HORARIO_MUY_CERCANO'; end if;
  if not p_fuera_de_horario and not public._within_hours(s.id, v_new) then raise exception 'FUERA_DE_HORARIO'; end if;
  if public._overlaps(s.id, v_occ, a.id) then raise exception 'HORARIO_OCUPADO'; end if;

  perform public._cancel_open_offers(a.id);

  if v_occ && a.occupied then
    if lower(v_occ) < lower(a.occupied) then
      v_hold := tstzrange(lower(v_occ), lower(a.occupied), '[)');
    elsif upper(v_occ) > upper(a.occupied) then
      v_hold := tstzrange(upper(a.occupied), upper(v_occ), '[)');
    end if;
  else
    v_hold := v_occ;
  end if;

  if v_hold is not null and not isempty(v_hold) then
    begin
      insert into agenda (shop_id, kind, status, period, hold_expires_at, reason)
      values (s.id, 'hold', 'active', v_hold, now() + interval '1 hour', 'Propuesta de cambio')
      returning id into v_hold_id;
    exception when exclusion_violation then
      raise exception 'HORARIO_OCUPADO';
    end;
  end if;

  insert into offers (shop_id, kind, appointment_id, original_period, proposed_period, hold_id, status, expires_at)
  values (s.id, 'proposal', a.id, a.period, v_new, v_hold_id, 'pending_approval', now() + interval '1 hour')
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
  s public.shops := public._require_admin();
  a public.agenda := public._my_appointment(s.id, p_turno_id);
begin
  perform public._set_actor('admin');
  if p_estado not in ('confirmed', 'completed', 'no_show') then raise exception 'ESTADO_INVALIDO'; end if;
  if p_estado = 'confirmed' and a.status <> 'pending' then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if p_estado in ('completed', 'no_show') then
    if a.status not in ('pending', 'confirmed', 'completed', 'no_show') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
    if lower(a.period) > now() then raise exception 'TURNO_AUN_NO_EMPEZO'; end if;
  end if;
  if p_estado <> 'confirmed' then perform public._cancel_open_offers(a.id); end if;
  update agenda set status = p_estado where id = a.id;
  return jsonb_build_object('estado', p_estado);
end $$;

create function public.admin_enlace_turno(p_turno_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s       public.shops := public._require_admin();
  a       public.agenda := public._my_appointment(s.id, p_turno_id);
  v_token text := public._new_token();
begin
  update agenda set manage_token_hash = public._hash(v_token) where id = a.id;
  return public._whatsapp_info(a.id) || jsonb_build_object('token', v_token);
end $$;

-- ---------------------------------------------------------------------
-- Bloqueos
-- ---------------------------------------------------------------------
create function public.admin_bloquear(
  p_desde timestamptz, p_hasta timestamptz, p_motivo text default null, p_cancelar_turnos boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s           public.shops := public._require_admin();
  v_range     tstzrange;
  v_conflicts jsonb;
  r           record;
  v_id        uuid;
begin
  perform public._set_actor('admin');
  if p_hasta <= p_desde then raise exception 'RANGO_INVALIDO'; end if;
  v_range := tstzrange(p_desde, p_hasta, '[)');

  select coalesce(jsonb_agg(public._whatsapp_info(a.id) order by lower(a.period)), '[]'::jsonb)
    into v_conflicts
    from agenda a
   where a.shop_id = s.id and a.kind = 'appointment' and a.status in ('pending', 'confirmed')
     and a.occupied && v_range;

  if jsonb_array_length(v_conflicts) > 0 and not p_cancelar_turnos then
    raise exception 'HAY_TURNOS_EN_CONFLICTO' using detail = v_conflicts::text;
  end if;

  for r in
    select id from agenda
     where shop_id = s.id and kind = 'appointment' and status in ('pending', 'confirmed') and occupied && v_range
     for update
  loop
    update agenda set status = 'cancelled_by_admin', cancelled_at = now(), reason = p_motivo where id = r.id;
    perform public._cancel_open_offers(r.id);
  end loop;

  for r in
    select o.id, o.hold_id from offers o join agenda h on h.id = o.hold_id
     where o.shop_id = s.id and o.status in ('pending_approval', 'sent') and h.status = 'active'
       and h.occupied && v_range
     for update of o
  loop
    perform public._release_hold(r.hold_id);
    update offers set status = 'cancelled', responded_at = now() where id = r.id;
  end loop;
  update agenda set status = 'released'
   where shop_id = s.id and kind = 'hold' and status = 'active' and occupied && v_range;

  begin
    insert into agenda (shop_id, kind, status, period, reason)
    values (s.id, 'block', 'active', v_range, nullif(btrim(coalesce(p_motivo, '')), ''))
    returning id into v_id;
  exception when exclusion_violation then
    raise exception 'RANGO_SUPERPUESTO';
  end;

  return jsonb_build_object('bloqueo_id', v_id, 'turnos_cancelados', v_conflicts);
end $$;

create function public.admin_bloquear_resto_jornada(
  p_desde timestamptz default now(), p_motivo text default null, p_cancelar_turnos boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s     public.shops := public._require_admin();
  v_fin timestamptz := (((p_desde at time zone s.timezone)::date + 1)::timestamp) at time zone s.timezone;
begin
  return public.admin_bloquear(p_desde, v_fin, p_motivo, p_cancelar_turnos);
end $$;

create function public.admin_bloquear_dias(
  p_desde date, p_hasta date, p_motivo text default null, p_cancelar_turnos boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._require_admin();
begin
  if p_hasta < p_desde then raise exception 'RANGO_INVALIDO'; end if;
  return public.admin_bloquear(p_desde::timestamp at time zone s.timezone,
                               (p_hasta + 1)::timestamp at time zone s.timezone,
                               p_motivo, p_cancelar_turnos);
end $$;

create function public.admin_quitar_bloqueo(p_bloqueo_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._require_admin();
begin
  perform public._set_actor('admin');
  update agenda set status = 'released'
   where id = p_bloqueo_id and shop_id = s.id and kind = 'block' and status = 'active';
  if not found then raise exception 'BLOQUEO_INEXISTENTE'; end if;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Panel de cancelación con mensajes personales
--   p_opcion 'elegir_otro': el cliente recibe un enlace para elegir otro horario
--            'solo_avisar': se cancela y se lo invita a reservar de nuevo
--   p_confirmar false = vista previa (no cambia nada); true = ejecuta
-- ---------------------------------------------------------------------
create function public._render_message(p_body text, p_appointment_id uuid, p_enlace text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select btrim(
           replace(replace(replace(replace(replace(replace(p_body,
             '{nombre}',   split_part(c.name, ' ', 1)),
             '{dia}',      public._fmt_dia(lower(a.period), s.timezone)),
             '{hora}',     public._fmt_hora(lower(a.period), s.timezone)),
             '{servicio}', a.service_name),
             '{negocio}',  s.business_name),
             '{enlace}',   coalesce(p_enlace, '')))
  from agenda a join customers c on c.id = a.customer_id join shops s on s.id = a.shop_id
  where a.id = p_appointment_id
$$;

create function public.admin_cancelar_y_avisar(
  p_desde        timestamptz,
  p_hasta        timestamptz,
  p_opcion       text,
  p_plantilla_id uuid default null,
  p_texto        text default null,
  p_motivo       text default null,
  p_confirmar    boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s        public.shops := public._require_admin();
  v_base   text := (select app_url from platform_settings where id);
  v_body   text;
  v_range  tstzrange;
  v_ids    uuid[];
  v_id     uuid;
  v_token  text;
  v_enlace text;
  v_msg    text;
  v_push   boolean;
  v_phone  text;
  v_list   jsonb := '[]'::jsonb;
  v_block  jsonb;
begin
  perform public._set_actor('admin');
  if p_opcion not in ('elegir_otro', 'solo_avisar') then raise exception 'OPCION_INVALIDA'; end if;
  if p_hasta <= p_desde then raise exception 'RANGO_INVALIDO'; end if;
  if v_base is null then raise exception 'FALTA_DIRECCION_APP'; end if;
  v_base := v_base || '/' || s.slug;

  if p_texto is not null and length(btrim(p_texto)) >= 10 then
    v_body := p_texto;
  else
    select body into v_body from message_templates where id = p_plantilla_id and shop_id = s.id and active;
    if v_body is null then raise exception 'PLANTILLA_INVALIDA'; end if;
  end if;

  v_range := tstzrange(p_desde, p_hasta, '[)');
  select coalesce(array_agg(id order by lower(period)), '{}') into v_ids
    from agenda
   where shop_id = s.id and kind = 'appointment' and status in ('pending', 'confirmed') and occupied && v_range;

  if not p_confirmar then
    foreach v_id in array v_ids loop
      v_enlace := case p_opcion when 'elegir_otro' then 'Elegí otro horario acá: ' || v_base || '/turno#…'
                                else 'Cuando quieras, reservá de nuevo acá: ' || v_base end;
      v_list := v_list || (public._whatsapp_info(v_id)
                           || jsonb_build_object('mensaje', public._render_message(v_body, v_id, v_enlace),
                                                 'tiene_push', exists (select 1 from push_subscriptions p
                                                                        join agenda a on a.customer_id = p.customer_id
                                                                       where a.id = v_id)));
    end loop;
    return jsonb_build_object('vista_previa', true, 'afectados', v_list);
  end if;

  v_block := public.admin_bloquear(p_desde, p_hasta, p_motivo, true);

  foreach v_id in array v_ids loop
    if p_opcion = 'elegir_otro' then
      v_token := public._new_token();
      update agenda set manage_token_hash = public._hash(v_token), can_rebook = true where id = v_id;
      v_enlace := 'Elegí otro horario acá: ' || v_base || '/turno#' || v_token;
    else
      v_enlace := 'Cuando quieras, reservá de nuevo acá: ' || v_base;
    end if;
    v_msg := public._render_message(v_body, v_id, v_enlace);

    v_push := public._queue_push(
      (select customer_id from agenda where id = v_id), null, 'admin_cancel', 'Cambio en tu turno', v_msg,
      case p_opcion when 'elegir_otro' then '/' || s.slug || '/turno#' || v_token else '/' || s.slug end);

    select c.phone into v_phone from agenda a join customers c on c.id = a.customer_id where a.id = v_id;
    v_list := v_list || (public._whatsapp_info(v_id)
                         || jsonb_build_object('mensaje', v_msg, 'tiene_push', v_push,
                                               'whatsapp_url', 'https://wa.me/' || v_phone || '?text=' || public._urlencode(v_msg)));
  end loop;

  return jsonb_build_object('vista_previa', false, 'bloqueo_id', v_block ->> 'bloqueo_id', 'afectados', v_list);
end $$;

-- ---------------------------------------------------------------------
-- Lista de espera desde el panel
-- ---------------------------------------------------------------------
create function public.admin_ofrecer_hueco(p_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._require_admin();
begin
  perform public._set_actor('admin');
  return jsonb_build_object('oferta_id', public._on_slot_freed(s.id, p_inicio, null));
end $$;

create function public.admin_aprobar_oferta(p_oferta_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s       public.shops := public._require_admin();
  o       public.offers;
  v_token text;
begin
  perform public._set_actor('admin');
  select * into o from offers where id = p_oferta_id and shop_id = s.id for update;
  if not found or o.status <> 'pending_approval' then raise exception 'OFERTA_NO_DISPONIBLE'; end if;
  if o.expires_at <= now() then raise exception 'OFERTA_VENCIDA'; end if;
  v_token := public._send_offer(o.id);
  return public._whatsapp_info(o.appointment_id)
         || jsonb_build_object('oferta_id', o.id, 'tipo', o.kind, 'token_oferta', v_token,
                               'inicio_propuesto', lower(o.proposed_period),
                               'vence', (select expires_at from offers where id = o.id));
end $$;

create function public.admin_descartar_oferta(p_oferta_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s      public.shops := public._require_admin();
  o      public.offers;
  v_next uuid;
begin
  perform public._set_actor('admin');
  select * into o from offers where id = p_oferta_id and shop_id = s.id for update;
  if not found or o.status not in ('pending_approval', 'sent') then raise exception 'OFERTA_NO_DISPONIBLE'; end if;
  perform public._release_hold(o.hold_id);
  update offers set status = 'cancelled', responded_at = now() where id = o.id;
  if o.kind = 'advance' then v_next := public._offer_next(o.freed_slot_id); end if;
  return jsonb_build_object('siguiente_oferta_id', v_next);
end $$;

create function public.admin_enlace_oferta(p_oferta_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s       public.shops := public._require_admin();
  o       public.offers;
  v_token text := public._new_token();
begin
  select * into o from offers where id = p_oferta_id and shop_id = s.id and status = 'sent' for update;
  if not found then raise exception 'OFERTA_NO_DISPONIBLE'; end if;
  update offers set token_hash = public._hash(v_token) where id = o.id;
  return public._whatsapp_info(o.appointment_id)
         || jsonb_build_object('oferta_id', o.id, 'tipo', o.kind, 'token_oferta', v_token,
                               'inicio_propuesto', lower(o.proposed_period), 'vence', o.expires_at);
end $$;

-- ---------------------------------------------------------------------
-- Avisos al celular del peluquero
-- ---------------------------------------------------------------------
create function public.admin_registrar_push(p_endpoint text, p_p256dh text, p_auth text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.shops := public._require_admin();
begin
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or length(coalesce(p_p256dh, '')) not between 20 and 200
     or length(coalesce(p_auth, '')) not between 8 and 100 then
    raise exception 'SUSCRIPCION_INVALIDA';
  end if;
  insert into admin_push_subscriptions (shop_id, endpoint, p256dh, auth) values (s.id, p_endpoint, p_p256dh, p_auth)
  on conflict (shop_id, endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Estadísticas
-- ---------------------------------------------------------------------
create function public.admin_estadisticas(p_desde date, p_hasta date) returns jsonb
language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  s     public.shops := public._require_admin();
  v_ini timestamptz := p_desde::timestamp at time zone s.timezone;
  v_fin timestamptz := (p_hasta + 1)::timestamp at time zone s.timezone;
  r     jsonb;
begin
  with t as (
    select a.*, (lower(a.period) at time zone s.timezone)::date as dia
      from agenda a
     where a.shop_id = s.id and a.kind = 'appointment' and lower(a.period) >= v_ini and lower(a.period) < v_fin
  )
  select jsonb_build_object(
    'total',      (select count(*) from t),
    'por_estado', coalesce((select jsonb_object_agg(status, n) from (select status, count(*) n from t group by status) x), '{}'),
    'por_dia',    coalesce((select jsonb_agg(jsonb_build_object('dia', dia, 'turnos', n) order by dia)
                              from (select dia, count(*) n from t
                                     where status not in ('cancelled_by_customer', 'cancelled_by_admin') group by dia) x), '[]'),
    'por_mes',    coalesce((select jsonb_agg(jsonb_build_object('mes', mes, 'turnos', n) order by mes)
                              from (select to_char(dia, 'YYYY-MM') mes, count(*) n from t
                                     where status not in ('cancelled_by_customer', 'cancelled_by_admin') group by 1) x), '[]'),
    'servicios_mas_pedidos', coalesce((select jsonb_agg(jsonb_build_object('servicio', service_name, 'turnos', n) order by n desc)
                              from (select service_name, count(*) n from t
                                     where status not in ('cancelled_by_customer', 'cancelled_by_admin') group by service_name) x), '[]'),
    'ingresos_estimados', coalesce((select sum(price) from t where status = 'completed'), 0),
    'cobros_por_medio', coalesce((select jsonb_object_agg(method, total)
                              from (select method, sum(amount) total from payments
                                     where shop_id = s.id and paid_at >= v_ini and paid_at < v_fin group by method) x), '{}'),
    'clientes_ausentes', coalesce((select jsonb_agg(jsonb_build_object('nombre', c.name, 'telefono', c.phone, 'ausencias', n) order by n desc)
                              from (select customer_id, count(*) n from t where status = 'no_show' group by customer_id) x
                              join customers c on c.id = x.customer_id), '[]')
  ) into r;
  return r;
end $$;
