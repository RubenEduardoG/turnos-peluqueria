-- =====================================================================
-- 06 · Seguridad: RLS y permisos
--
--  · anon (clientes sin cuenta): NINGÚN acceso a tablas; sólo ejecuta las
--    funciones públicas de la app de clientes.
--  · authenticated: sólo el administrador ve y modifica datos (is_admin()).
--    El registro público de usuarios debe quedar deshabilitado en Supabase.
--  · Las funciones internas (_algo) no las puede ejecutar nadie desde la API.
-- =====================================================================

-- RLS en todas las tablas
alter table public.settings           enable row level security;
alter table public.services           enable row level security;
alter table public.working_hours      enable row level security;
alter table public.customers          enable row level security;
alter table public.agenda             enable row level security;
alter table public.freed_slots        enable row level security;
alter table public.offers             enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notification_queue enable row level security;
alter table public.payments           enable row level security;
alter table public.events             enable row level security;

-- Sin permisos por defecto
revoke all on all tables    in schema public from anon, authenticated;
revoke all on all sequences in schema public from anon, authenticated;

-- Permisos del administrador (siempre filtrados además por RLS)
grant select                         on public.settings      to authenticated;
grant update (business_name, whatsapp_phone, timezone, booking_enabled, auto_confirm,
              slot_step_minutes, min_booking_notice_minutes, max_booking_days_ahead, allow_same_day,
              min_cancel_notice_minutes, min_reschedule_notice_minutes,
              max_active_appointments_per_phone, no_show_block_threshold, offers_mode,
              offer_response_minutes, offer_min_lead_minutes, proposal_response_hours)
                                     on public.settings      to authenticated;
grant select, insert, update, delete on public.services      to authenticated;
grant select, insert, update, delete on public.working_hours to authenticated;
grant select, update (name, email, notes) on public.customers to authenticated;
grant select, update (admin_note)    on public.agenda        to authenticated;
grant select                         on public.freed_slots   to authenticated;
grant select                         on public.offers        to authenticated;
grant select                         on public.notification_queue to authenticated;
grant select, insert, update, delete on public.payments      to authenticated;
grant select                         on public.events        to authenticated;

create policy admin_all on public.settings      for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.services      for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.working_hours for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.customers     for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.agenda        for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.freed_slots   for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.offers        for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.notification_queue for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.payments      for all to authenticated using (public.is_admin()) with check (public.is_admin());
create policy admin_all on public.events        for all to authenticated using (public.is_admin()) with check (public.is_admin());
-- push_subscriptions: sin políticas → nadie la lee por la API (sólo la Edge Function con service_role)

-- ---------------------------------------------------------------------
-- Funciones: cerrar todo y abrir sólo lo necesario
-- ---------------------------------------------------------------------
revoke execute on all functions in schema public from public, anon, authenticated;
alter default privileges in schema public revoke execute on functions from public, anon, authenticated;

-- App de clientes (anon) y también usuarios logueados
grant execute on function
  public.info_negocio(),
  public.servicios_publicos(),
  public.horarios_disponibles(uuid, date),
  public.dias_disponibles(uuid, date, date),
  public.reservar(uuid, timestamptz, text, text, text, text, boolean, boolean),
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

-- Panel (cada función verifica además que sea el administrador)
grant execute on function
  public.is_admin(),
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
  public.admin_ofrecer_hueco(timestamptz),
  public.admin_aprobar_oferta(uuid),
  public.admin_descartar_oferta(uuid),
  public.admin_enlace_oferta(uuid),
  public.admin_estadisticas(date, date)
to authenticated;

-- Las políticas RLS llaman a is_admin() con el rol del usuario
grant execute on function public.is_admin() to anon;

-- ---------------------------------------------------------------------
-- Realtime para el panel (sólo si existe la publicación de Supabase)
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.agenda, public.offers;
  end if;
end $$;
