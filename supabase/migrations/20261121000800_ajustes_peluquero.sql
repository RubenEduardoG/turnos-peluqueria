-- =====================================================================
-- 08 · Ajustes pedidos el 21/11/2026
--
--  1. Reservas y cambios hasta 5 días hacia adelante; el cliente cambia su
--     horario solo, sin aprobación. Al peluquero le llega un aviso push por
--     cada reserva, cambio o cancelación hecha por un cliente.
--  2. Lista de espera 100 % automática: sólo participan clientes con
--     notificaciones activadas (sin push no hay forma gratuita de avisarles).
--  3. Panel de cancelación: bloquear un rango, elegir qué pasa con los
--     turnos afectados y un mensaje (plantillas), con vista previa de un
--     mensaje personal por cliente antes de confirmar.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Configuración
-- ---------------------------------------------------------------------
alter table public.settings
  alter column max_booking_days_ahead set default 5,
  alter column offers_mode set default 'auto',
  add column public_app_url text check (public_app_url is null or public_app_url ~ '^https://[^\s]+[^/]$');

update public.settings set max_booking_days_ahead = 5, offers_mode = 'auto';

comment on column public.settings.public_app_url is 'Dirección de la app de clientes, sin barra final (p. ej. https://mi-peluqueria.pages.dev). Se usa en los enlaces de WhatsApp.';

grant update (public_app_url) on public.settings to authenticated;

-- Turnos cancelados por el peluquero que el cliente puede volver a ubicar con su enlace
alter table public.agenda add column can_rebook boolean not null default false;

-- ---------------------------------------------------------------------
-- Avisos al peluquero
-- ---------------------------------------------------------------------
create table public.admin_push_subscriptions (
  id         uuid primary key default gen_random_uuid(),
  endpoint   text not null unique,
  p256dh     text not null,
  auth       text not null,
  created_at timestamptz not null default now()
);
alter table public.admin_push_subscriptions enable row level security;
create policy admin_all on public.admin_push_subscriptions for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, delete on public.admin_push_subscriptions to authenticated;

alter table public.notification_queue
  alter column customer_id drop not null,
  add column to_admin boolean not null default false,
  add constraint notification_target check (to_admin or customer_id is not null);

-- ---------------------------------------------------------------------
-- Plantillas de mensajes para cancelaciones del peluquero
-- Variables: {nombre} {dia} {hora} {servicio} {negocio} {enlace}
-- ---------------------------------------------------------------------
create table public.message_templates (
  id         uuid primary key default gen_random_uuid(),
  title      text not null check (length(btrim(title)) between 1 and 60),
  body       text not null check (length(body) between 10 and 1000),
  sort_order int not null default 0,
  active     boolean not null default true
);
alter table public.message_templates enable row level security;
create policy admin_all on public.message_templates for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.message_templates to authenticated;

insert into public.message_templates (title, body, sort_order) values
  ('Imprevisto',
   'Hola {nombre}, ¿cómo estás? Te escribo porque por un imprevisto no voy a poder atenderte el {dia} a las {hora}. Disculpá las molestias. {enlace}', 1),
  ('Problema de salud',
   'Hola {nombre}, ¿cómo estás? Por un problema de salud no voy a poder atenderte el {dia} a las {hora}. Perdón por avisarte sobre la hora. {enlace}', 2),
  ('Problema en el local',
   'Hola {nombre}, ¿cómo estás? Tuvimos un problema en el local y no vamos a poder atenderte el {dia} a las {hora}. Disculpá las molestias. {enlace}', 3),
  ('Cambio de agenda',
   'Hola {nombre}, ¿cómo estás? Necesito modificar mi agenda y tu turno del {dia} a las {hora} queda suspendido. {enlace}', 4),
  ('Mensaje del documento',
   'Hola, ¿cómo estás? Te escribimos para avisarte que por un imprevisto necesitamos modificar tu turno del {dia} a las {hora}. Disculpá las molestias. {enlace}', 5);

-- ---------------------------------------------------------------------
-- Formatos
-- ---------------------------------------------------------------------
create function public._fmt_dia(p_at timestamptz) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select (array['domingo','lunes','martes','miércoles','jueves','viernes','sábado'])
           [extract(dow from p_at at time zone s.timezone)::int + 1]
         || ' ' || to_char(p_at at time zone s.timezone, 'DD/MM')
  from settings s where s.id
$$;

create function public._fmt_hora(p_at timestamptz) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select to_char(p_at at time zone s.timezone, 'HH24:MI') from settings s where s.id
$$;

create function public._render_message(p_body text, p_appointment_id uuid, p_enlace text) returns text
language sql stable security definer set search_path = public, pg_temp as $$
  select btrim(
           replace(replace(replace(replace(replace(replace(p_body,
             '{nombre}',   split_part(c.name, ' ', 1)),
             '{dia}',      public._fmt_dia(lower(a.period))),
             '{hora}',     public._fmt_hora(lower(a.period))),
             '{servicio}', a.service_name),
             '{negocio}',  coalesce(s.business_name, '')),
             '{enlace}',   coalesce(p_enlace, '')))
  from agenda a join customers c on c.id = a.customer_id, settings s
  where a.id = p_appointment_id and s.id
$$;

-- ---------------------------------------------------------------------
-- Aviso automático al peluquero (reservas, cambios y cancelaciones de clientes)
-- ---------------------------------------------------------------------
create function public._notify_admin() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor text := coalesce(nullif(current_setting('app.actor', true), ''), 'system');
  v_name  text;
  v_title text;
  v_body  text;
begin
  if new.kind <> 'appointment' or v_actor = 'admin' then return null; end if;
  if not exists (select 1 from admin_push_subscriptions) then return null; end if;

  select name into v_name from customers where id = new.customer_id;

  if tg_op = 'INSERT' then
    v_title := 'Nueva reserva';
    v_body  := format('%s · %s · %s %s', v_name, new.service_name,
                      public._fmt_dia(lower(new.period)), public._fmt_hora(lower(new.period)));
  elsif new.status = 'cancelled_by_customer' and old.status <> new.status then
    v_title := 'Turno cancelado';
    v_body  := format('%s canceló su turno del %s a las %s', v_name,
                      public._fmt_dia(lower(new.period)), public._fmt_hora(lower(new.period)));
  elsif new.period is distinct from old.period then
    v_title := 'Turno cambiado';
    v_body  := format('%s pasó del %s %s al %s %s', v_name,
                      public._fmt_dia(lower(old.period)), public._fmt_hora(lower(old.period)),
                      public._fmt_dia(lower(new.period)), public._fmt_hora(lower(new.period)));
  else
    return null;
  end if;

  insert into notification_queue (to_admin, kind, title, body, url)
  values (true, 'admin_' || lower(replace(v_title, ' ', '_')), v_title, v_body,
          '/admin/agenda?dia=' || ((lower(new.period) at time zone (public._settings()).timezone)::date)::text);
  return null;
end $$;

create trigger agenda_notify_admin after insert or update on public.agenda
  for each row execute function public._notify_admin();

create function public.admin_registrar_push(p_endpoint text, p_p256dh text, p_auth text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._require_admin();
  if p_endpoint !~ '^https://' or length(p_endpoint) > 1000
     or length(coalesce(p_p256dh, '')) not between 20 and 200
     or length(coalesce(p_auth, '')) not between 8 and 100 then
    raise exception 'SUSCRIPCION_INVALIDA';
  end if;
  insert into admin_push_subscriptions (endpoint, p256dh, auth) values (p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update set p256dh = excluded.p256dh, auth = excluded.auth;
  return jsonb_build_object('ok', true);
end $$;

-- ---------------------------------------------------------------------
-- Lista de espera: sólo clientes con notificaciones; sin aprobaciones en modo auto
-- ---------------------------------------------------------------------
create or replace function public._offer_next(p_freed_slot_id uuid) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s            public.settings := public._settings();
  fs           public.freed_slots;
  cand         public.agenda;
  v_response   interval := make_interval(mins => s.offer_response_minutes);
  v_deadline   timestamptz;
  v_new_period tstzrange;
  v_new_occ    tstzrange;
  v_hold_id    uuid;
  v_offer_id   uuid;
begin
  if p_freed_slot_id is null then return null; end if;

  select * into fs from freed_slots where id = p_freed_slot_id for update;
  if not found or fs.status not in ('open', 'offering') then return null; end if;

  v_deadline := fs.start_at - make_interval(mins => s.offer_min_lead_minutes);
  if s.offers_mode = 'off' or now() + v_response > v_deadline then
    update freed_slots set status = 'exhausted' where id = fs.id;
    return null;
  end if;

  for cand in
    select a.* from agenda a
    where a.kind = 'appointment'
      and a.status in ('pending', 'confirmed')
      and a.wants_earlier
      and exists (select 1 from push_subscriptions p where p.customer_id = a.customer_id)
      and a.id is distinct from fs.origin_appointment_id
      and lower(a.period) > fs.start_at
      and (lower(a.period) at time zone s.timezone)::date = fs.local_day
      and not exists (select 1 from offers o where o.freed_slot_id = fs.id and o.appointment_id = a.id)
      and not exists (select 1 from offers o where o.appointment_id = a.id
                                                and o.status in ('pending_approval', 'sent'))
    order by lower(a.period), a.created_at
  loop
    v_new_period := tstzrange(fs.start_at, fs.start_at + make_interval(mins => cand.duration_minutes), '[)');
    v_new_occ    := tstzrange(fs.start_at, upper(v_new_period) + make_interval(mins => cand.buffer_minutes), '[)');

    continue when not public._within_hours(v_new_period);
    continue when public._overlaps(v_new_occ, cand.id);

    begin
      insert into agenda (kind, status, period, hold_expires_at, reason)
      values ('hold', 'active',
              tstzrange(fs.start_at, least(upper(v_new_occ), lower(cand.occupied)), '[)'),
              v_deadline, 'Oferta de adelanto')
      returning id into v_hold_id;
    exception when exclusion_violation then
      continue;
    end;

    insert into offers (kind, appointment_id, freed_slot_id, original_period, proposed_period,
                        hold_id, status, expires_at, has_push)
    values ('advance', cand.id, fs.id, cand.period, v_new_period,
            v_hold_id, 'pending_approval', v_deadline - v_response, true)
    returning id into v_offer_id;

    update freed_slots set status = 'offering' where id = fs.id;

    if s.offers_mode = 'auto' then
      perform public._send_offer(v_offer_id);
    end if;
    return v_offer_id;
  end loop;

  update freed_slots set status = 'exhausted' where id = fs.id;
  return null;
end $$;

-- "Avisarme si se libera antes" requiere notificaciones activadas
create or replace function public.preferencia_adelanto(p_token text, p_activar boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  a public.agenda;
begin
  perform public._set_actor('customer');
  a := public._appointment_by_token(p_token);
  if a.status not in ('pending', 'confirmed') then raise exception 'TURNO_NO_MODIFICABLE'; end if;
  if coalesce(p_activar, false)
     and not exists (select 1 from push_subscriptions where customer_id = a.customer_id) then
    raise exception 'NECESITA_NOTIFICACIONES';
  end if;
  update agenda set wants_earlier = coalesce(p_activar, false) where id = a.id;
  return jsonb_build_object('avisar_antes', coalesce(p_activar, false));
end $$;

-- ---------------------------------------------------------------------
-- Reprogramar: también vale para turnos que el peluquero suspendió
-- con la opción "que el cliente elija otro horario"
-- ---------------------------------------------------------------------
create or replace function public.reprogramar_turno(p_token text, p_nuevo_inicio timestamptz) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s public.settings := public._settings();
  a public.agenda;
  r jsonb;
begin
  perform public._set_actor('customer');
  if not s.booking_enabled then raise exception 'RESERVAS_DESHABILITADAS'; end if;
  perform public._procesar_vencimientos();
  a := public._appointment_by_token(p_token);

  if a.status = 'cancelled_by_admin' and a.can_rebook then
    -- El horario viejo quedó bloqueado por el peluquero: no se libera ni se aplica el plazo.
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

drop function public.mis_turnos(text[]);
create function public.mis_turnos(p_tokens text[])
returns table (
  token text, id uuid, servicio text, precio numeric, inicio timestamptz, fin timestamptz,
  estado text, avisar_antes boolean, puede_cancelar boolean, puede_reprogramar boolean,
  debe_elegir_horario boolean, oferta jsonb
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
     order by lower(a.period);
end $$;
grant execute on function public.mis_turnos(text[]) to anon, authenticated;

-- ---------------------------------------------------------------------
-- Panel de cancelación del peluquero
--
-- p_opcion:
--   'elegir_otro'  → se suspende el turno y el cliente elige otro horario con su enlace
--   'solo_avisar'  → se cancela y se lo invita a reservar de nuevo cuando quiera
-- p_confirmar = false → VISTA PREVIA: no cambia nada, devuelve los mensajes.
-- p_confirmar = true  → bloquea el rango, cancela, envía push a quien lo tenga
--                       y devuelve los mensajes con teléfono para WhatsApp.
-- p_texto: mensaje propio en lugar de una plantilla (mismas variables).
-- ---------------------------------------------------------------------
create function public.admin_cancelar_y_avisar(
  p_desde       timestamptz,
  p_hasta       timestamptz,
  p_opcion      text,
  p_plantilla_id uuid default null,
  p_texto       text default null,
  p_motivo      text default null,
  p_confirmar   boolean default false
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s        public.settings := public._settings();
  v_body   text;
  v_range  tstzrange;
  v_ids    uuid[];
  v_id     uuid;
  v_token  text;
  v_enlace text;
  v_msg    text;
  v_push   boolean;
  v_list   jsonb := '[]'::jsonb;
  v_block  jsonb;
begin
  perform public._require_admin();
  perform public._set_actor('admin');

  if p_opcion not in ('elegir_otro', 'solo_avisar') then raise exception 'OPCION_INVALIDA'; end if;
  if p_hasta <= p_desde then raise exception 'RANGO_INVALIDO'; end if;
  if s.public_app_url is null then raise exception 'FALTA_DIRECCION_APP'; end if;

  if p_texto is not null and length(btrim(p_texto)) >= 10 then
    v_body := p_texto;
  else
    select body into v_body from message_templates where id = p_plantilla_id and active;
    if v_body is null then raise exception 'PLANTILLA_INVALIDA'; end if;
  end if;

  v_range := tstzrange(p_desde, p_hasta, '[)');
  select coalesce(array_agg(id order by lower(period)), '{}') into v_ids
    from agenda
   where kind = 'appointment' and status in ('pending', 'confirmed') and occupied && v_range;

  if not p_confirmar then
    foreach v_id in array v_ids loop
      v_enlace := case p_opcion
                    when 'elegir_otro' then 'Elegí otro horario acá: ' || s.public_app_url || '/turno#…'
                    else 'Cuando quieras, reservá de nuevo acá: ' || s.public_app_url end;
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
    -- "Elegir otro": enlace nuevo para incluir en el mensaje (en la base sólo hay huellas).
    -- "Sólo avisar": el cliente conserva su enlace y ve el turno como cancelado.
    if p_opcion = 'elegir_otro' then
      v_token := public._new_token();
      update agenda set manage_token_hash = public._hash(v_token), can_rebook = true where id = v_id;
    end if;

    v_enlace := case p_opcion
                  when 'elegir_otro' then 'Elegí otro horario acá: ' || s.public_app_url || '/turno#' || v_token
                  else 'Cuando quieras, reservá de nuevo acá: ' || s.public_app_url end;
    v_msg := public._render_message(v_body, v_id, v_enlace);

    v_push := public._queue_push(
      (select customer_id from agenda where id = v_id), null, 'admin_cancel',
      'Cambio en tu turno', v_msg,
      case p_opcion when 'elegir_otro' then '/turno#' || v_token else '/' end);

    v_list := v_list || (public._whatsapp_info(v_id)
                         || jsonb_build_object('mensaje', v_msg, 'tiene_push', v_push,
                                               'whatsapp_url', 'https://wa.me/' ||
                                                 (select c.phone from agenda a join customers c on c.id = a.customer_id where a.id = v_id)
                                                 || '?text=' || public._urlencode(v_msg)));
  end loop;

  return jsonb_build_object('vista_previa', false, 'bloqueo_id', v_block ->> 'bloqueo_id', 'afectados', v_list);
end $$;

create function public._urlencode(p_text text) returns text
language plpgsql immutable set search_path = public, pg_temp as $$
declare
  b   bytea := convert_to(p_text, 'UTF8');
  r   text := '';
  c   int;
  i   int;
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

-- ---------------------------------------------------------------------
-- Permisos de lo nuevo
-- ---------------------------------------------------------------------
revoke execute on function
  public._fmt_dia(timestamptz), public._fmt_hora(timestamptz),
  public._render_message(text, uuid, text), public._notify_admin(), public._urlencode(text)
from public, anon, authenticated;

grant execute on function
  public.admin_registrar_push(text, text, text),
  public.admin_cancelar_y_avisar(timestamptz, timestamptz, text, uuid, text, text, boolean)
to authenticated;
