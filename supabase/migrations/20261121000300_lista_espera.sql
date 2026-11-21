-- =====================================================================
-- 03 · Lista de espera inteligente (por peluquería)
--
--   1. Se libera un horario (cancelación o cambio del cliente, cliente que
--      adelanta, o el peluquero lo pide con admin_ofrecer_hueco).
--   2. _offer_next busca el turno más cercano del MISMO día, posterior al
--      hueco, que pidió "avisarme si se libera antes" y tiene
--      notificaciones activadas, cuyo servicio entre en el hueco (contando
--      su propio turno si es contiguo) y dentro del horario de atención.
--   3. Se RETIENE el hueco mientras se espera la respuesta.
--   4. Aceptar mueve el turno en una sola transacción y ofrece el horario
--      que dejó libre (cascada). Rechazar o vencer pasa al siguiente.
--
-- offers_mode 'auto' (por defecto): sin aprobaciones. 'approval': el
-- peluquero aprueba cada oferta. 'off': sin lista de espera.
-- =====================================================================

create function public._send_offer(p_offer_id uuid) returns text
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o        public.offers;
  a        public.agenda;
  s        public.shops;
  v_token  text := public._new_token();
  v_exp    timestamptz;
  v_push   boolean;
begin
  select * into o from offers where id = p_offer_id for update;
  select * into a from agenda where id = o.appointment_id;
  s := public._shop(o.shop_id);

  if o.kind = 'advance' then
    v_exp := now() + make_interval(mins => s.offer_response_minutes);
  else
    v_exp := least(now() + make_interval(hours => s.proposal_response_hours),
                   lower(o.proposed_period) - make_interval(mins => s.offer_min_lead_minutes));
  end if;

  v_push := public._queue_push(
    a.customer_id, o.id, o.kind,
    case o.kind when 'advance' then 'Se liberó un turno más temprano' else 'Te proponemos otro horario' end,
    case o.kind
      when 'advance' then format('Se liberó un turno %s. Tenés reservado %s. ¿Querés adelantarlo?',
                                 public._fmt_when(lower(o.proposed_period), s.timezone),
                                 public._fmt_when(lower(o.original_period), s.timezone))
      else format('Necesitamos modificar tu turno. ¿Te queda bien %s?',
                  public._fmt_when(lower(o.proposed_period), s.timezone))
    end,
    '/' || s.slug || '/oferta#' || v_token);

  update offers
     set status = 'sent', token_hash = public._hash(v_token), expires_at = v_exp,
         sent_at = now(), has_push = v_push
   where id = o.id;
  update agenda set hold_expires_at = v_exp where id = o.hold_id;
  return v_token;
end $$;

create function public._offer_next(p_freed_slot_id uuid) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  fs           public.freed_slots;
  s            public.shops;
  cand         public.agenda;
  v_response   interval;
  v_deadline   timestamptz;
  v_new_period tstzrange;
  v_new_occ    tstzrange;
  v_hold_id    uuid;
  v_offer_id   uuid;
begin
  if p_freed_slot_id is null then return null; end if;

  select * into fs from freed_slots where id = p_freed_slot_id for update;
  if not found or fs.status not in ('open', 'offering') then return null; end if;
  s := public._shop(fs.shop_id);

  v_response := make_interval(mins => s.offer_response_minutes);
  v_deadline := fs.start_at - make_interval(mins => s.offer_min_lead_minutes);
  if s.offers_mode = 'off' or not public._shop_active(s) or now() + v_response > v_deadline then
    update freed_slots set status = 'exhausted' where id = fs.id;
    return null;
  end if;

  for cand in
    select a.* from agenda a
    where a.shop_id = fs.shop_id
      and a.kind = 'appointment'
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

    continue when not public._within_hours(s.id, v_new_period);
    continue when public._overlaps(s.id, v_new_occ, cand.id);

    begin
      insert into agenda (shop_id, kind, status, period, hold_expires_at, reason)
      values (s.id, 'hold', 'active',
              tstzrange(fs.start_at, least(upper(v_new_occ), lower(cand.occupied)), '[)'),
              v_deadline, 'Oferta de adelanto')
      returning id into v_hold_id;
    exception when exclusion_violation then
      continue;
    end;

    insert into offers (shop_id, kind, appointment_id, freed_slot_id, original_period, proposed_period,
                        hold_id, status, expires_at, has_push)
    values (s.id, 'advance', cand.id, fs.id, cand.period, v_new_period,
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

create function public._on_slot_freed(p_shop_id uuid, p_start timestamptz, p_origin uuid) returns uuid
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s    public.shops := public._shop(p_shop_id);
  v_id uuid;
begin
  if s.offers_mode = 'off' or p_start <= now() then return null; end if;
  insert into freed_slots (shop_id, start_at, local_day, origin_appointment_id)
  values (s.id, p_start, (p_start at time zone s.timezone)::date, p_origin)
  returning id into v_id;
  return public._offer_next(v_id);
end $$;

create function public._respond_offer(p_offer_id uuid, p_accept boolean) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o     public.offers;
  a     public.agenda;
  v_old tstzrange;
begin
  select * into o from offers where id = p_offer_id for update;
  if not found or o.status <> 'sent' then
    return jsonb_build_object('result', 'no_disponible');
  end if;

  if o.expires_at <= now() then
    perform public._release_hold(o.hold_id);
    update offers set status = 'expired', responded_at = now() where id = o.id;
    if o.kind = 'advance' then perform public._offer_next(o.freed_slot_id); end if;
    return jsonb_build_object('result', 'vencida');
  end if;

  select * into a from agenda where id = o.appointment_id for update;
  if a.status not in ('pending', 'confirmed') or a.period is distinct from o.original_period then
    perform public._release_hold(o.hold_id);
    update offers set status = 'cancelled', responded_at = now() where id = o.id;
    if o.kind = 'advance' then perform public._offer_next(o.freed_slot_id); end if;
    return jsonb_build_object('result', 'no_disponible');
  end if;

  if not p_accept then
    perform public._release_hold(o.hold_id);
    update offers set status = 'declined', responded_at = now() where id = o.id;
    if o.kind = 'advance' then perform public._offer_next(o.freed_slot_id); end if;
    return jsonb_build_object('result', 'rechazada');
  end if;

  v_old := a.period;
  perform public._release_hold(o.hold_id);
  begin
    update agenda set period = o.proposed_period where id = a.id;
  exception when exclusion_violation then
    update offers set status = 'cancelled', responded_at = now() where id = o.id;
    if o.kind = 'advance' then perform public._offer_next(o.freed_slot_id); end if;
    return jsonb_build_object('result', 'no_disponible');
  end;

  update offers set status = 'accepted', responded_at = now() where id = o.id;

  if o.kind = 'advance' then
    update freed_slots set status = 'filled' where id = o.freed_slot_id;
    perform public._on_slot_freed(a.shop_id, lower(v_old), a.id);   -- cascada
  end if;

  return jsonb_build_object('result', 'aceptada',
                            'start', lower(o.proposed_period), 'end', upper(o.proposed_period));
end $$;

-- Tarea programada (cada minuto, todas las peluquerías)
create function public._procesar_vencimientos() returns int
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  o public.offers;
  n int := 0;
begin
  if not pg_try_advisory_xact_lock(hashtext('turnos:procesar_vencimientos')) then
    return 0;
  end if;
  perform public._set_actor('system');

  for o in
    select * from offers
    where status in ('pending_approval', 'sent') and expires_at <= now()
    order by expires_at
    for update skip locked
  loop
    perform public._release_hold(o.hold_id);
    update offers set status = 'expired', responded_at = now() where id = o.id;
    if o.kind = 'advance' then perform public._offer_next(o.freed_slot_id); end if;
    n := n + 1;
  end loop;

  update agenda set status = 'released'
   where kind = 'hold' and status = 'active' and hold_expires_at <= now();

  update freed_slots fs set status = 'exhausted'
   where fs.status in ('open', 'offering') and fs.start_at <= now()
     and not exists (select 1 from offers x where x.freed_slot_id = fs.id
                                              and x.status in ('pending_approval', 'sent'));
  return n;
end $$;
