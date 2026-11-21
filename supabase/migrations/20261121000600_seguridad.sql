-- =====================================================================
-- 06 · Seguridad: RLS y permisos
--
--  · anon (clientes sin cuenta): NINGÚN acceso a tablas; sólo ejecuta las
--    funciones públicas, que reciben la dirección de la peluquería.
--  · authenticated (peluqueros): ven y modifican SÓLO las filas de su
--    peluquería (shop_id = my_shop_id()).
--  · Dueño de la plataforma: ve todas las peluquerías y sus pagos; las
--    activa y suspende con funciones super_*.
--  · Las funciones internas (_algo) no las ejecuta nadie desde la API.
-- =====================================================================

alter table public.platform_admins          enable row level security;
alter table public.platform_settings        enable row level security;
alter table public.shops                    enable row level security;
alter table public.services                 enable row level security;
alter table public.working_hours            enable row level security;
alter table public.customers                enable row level security;
alter table public.agenda                   enable row level security;
alter table public.freed_slots              enable row level security;
alter table public.offers                   enable row level security;
alter table public.push_subscriptions       enable row level security;
alter table public.admin_push_subscriptions enable row level security;
alter table public.notification_queue       enable row level security;
alter table public.message_templates        enable row level security;
alter table public.payments                 enable row level security;
alter table public.subscription_payments    enable row level security;
alter table public.events                   enable row level security;

revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Al insertar, shop_id se completa solo con la peluquería del usuario
alter table public.services          alter column shop_id set default public.my_shop_id();
alter table public.working_hours     alter column shop_id set default public.my_shop_id();
alter table public.message_templates alter column shop_id set default public.my_shop_id();
alter table public.payments          alter column shop_id set default public.my_shop_id();

-- ---------------------------------------------------------------------
-- Peluquería propia: lectura y configuración (no el estado, el pago, el
-- dueño ni la dirección, que la ven sus clientes en el QR)
-- ---------------------------------------------------------------------
grant select on public.shops to authenticated;
grant update (business_name, whatsapp_phone, address, timezone, booking_enabled, auto_confirm,
              slot_step_minutes, min_booking_notice_minutes, max_booking_days_ahead, allow_same_day,
              min_cancel_notice_minutes, min_reschedule_notice_minutes,
              max_active_appointments_per_phone, no_show_block_threshold, offers_mode,
              offer_response_minutes, offer_min_lead_minutes, proposal_response_hours)
  on public.shops to authenticated;

create policy shop_owner_select on public.shops for select to authenticated
  using (owner_user_id = auth.uid() or public.is_platform_admin());
create policy shop_owner_update on public.shops for update to authenticated
  using (owner_user_id = auth.uid()) with check (owner_user_id = auth.uid());

-- ---------------------------------------------------------------------
-- Tablas de cada peluquería
-- ---------------------------------------------------------------------
grant select, insert, update, delete on public.services          to authenticated;
grant select, insert, update, delete on public.working_hours     to authenticated;
grant select, insert, update, delete on public.message_templates to authenticated;
grant select, insert, update, delete on public.payments          to authenticated;
grant select, update (name, email, notes) on public.customers    to authenticated;
grant select, update (admin_note)    on public.agenda            to authenticated;
grant select                         on public.freed_slots       to authenticated;
grant select                         on public.offers            to authenticated;
grant select                         on public.notification_queue to authenticated;
grant select                         on public.events            to authenticated;
grant select, delete                 on public.admin_push_subscriptions to authenticated;

create policy own_shop on public.services                 for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.working_hours            for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.message_templates        for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.payments                 for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.customers                for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.agenda                   for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.freed_slots              for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.offers                   for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.notification_queue       for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.events                   for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
create policy own_shop on public.admin_push_subscriptions for all to authenticated using (shop_id = public.my_shop_id()) with check (shop_id = public.my_shop_id());
-- push_subscriptions de clientes: sin políticas (sólo la Edge Function con service_role)

-- Pagos a la plataforma: el peluquero ve los suyos; el dueño de la plataforma, todos
grant select on public.subscription_payments to authenticated;
create policy own_or_platform on public.subscription_payments for select to authenticated
  using (shop_id = public.my_shop_id() or public.is_platform_admin());

grant select on public.platform_settings to authenticated;
create policy platform_read on public.platform_settings for select to authenticated using (public.is_platform_admin());

-- ---------------------------------------------------------------------
-- Funciones
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- App de clientes
grant execute on function
  public.ping(),
  public.info_negocio(text),
  public.servicios_publicos(text),
  public.horarios_disponibles(text, uuid, date),
  public.dias_disponibles(text, uuid, date, date),
  public.reservar(text, uuid, timestamptz, text, text, text, text, boolean),
  public.mis_turnos(text[]),
  public.cancelar_turno(text),
  public.reprogramar_turno(text, timestamptz),
  public.horarios_para_mi_turno(text, date),
  public.preferencia_adelanto(text, boolean),
  public.ver_oferta(text),
  public.responder_oferta(text, boolean),
  public.responder_oferta_de_mi_turno(text, boolean),
  public.elegir_otro_horario(text, timestamptz),
  public.registrar_push(text, text, text, text)
to anon, authenticated;

-- Panel del peluquero
grant execute on function
  public.my_shop_id(),
  public.is_platform_admin(),
  public.registrar_peluqueria(text, text, text),
  public.mi_peluqueria(),
  public.admin_crear_turno(text, text, uuid, timestamptz, text, boolean),
  public.admin_cancelar_turno(uuid, text, boolean),
  public.admin_reprogramar_turno(uuid, timestamptz, boolean, boolean),
  public.admin_proponer_horario(uuid, timestamptz, boolean),
  public.admin_marcar_turno(uuid, text),
  public.admin_enlace_turno(uuid),
  public.admin_bloquear(timestamptz, timestamptz, text, boolean),
  public.admin_bloquear_resto_jornada(timestamptz, text, boolean),
  public.admin_bloquear_dias(date, date, text, boolean),
  public.admin_quitar_bloqueo(uuid),
  public.admin_cancelar_y_avisar(timestamptz, timestamptz, text, uuid, text, text, boolean),
  public.admin_ofrecer_hueco(timestamptz),
  public.admin_aprobar_oferta(uuid),
  public.admin_descartar_oferta(uuid),
  public.admin_enlace_oferta(uuid),
  public.admin_registrar_push(text, text, text),
  public.admin_estadisticas(date, date)
to authenticated;

-- Panel de la plataforma (cada función verifica además que sea dueño)
grant execute on function
  public.super_peluquerias(),
  public.super_activar(uuid, date, numeric, text),
  public.super_suspender(uuid),
  public.super_configurar(text)
to authenticated;

-- ---------------------------------------------------------------------
-- Realtime para el panel (sólo si existe la publicación de Supabase)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.agenda, public.offers;
  end if;
end $$;
