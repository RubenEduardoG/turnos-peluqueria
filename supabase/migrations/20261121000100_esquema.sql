-- =====================================================================
-- 01 · Esquema base
-- Turnos para un peluquero independiente (un solo profesional).
--
-- Regla central: todo lo que ocupa tiempo en la agenda (turnos,
-- retenciones temporales y bloqueos) vive en la tabla `agenda`, y una
-- restricción de exclusión impide que dos filas activas se superpongan.
-- La garantía contra reservas duplicadas la da la base, no la app.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Configuración del negocio (una sola fila)
-- Los valores por defecto son provisorios: la reserva online arranca
-- DESHABILITADA (booking_enabled = false) hasta que el peluquero cargue
-- sus datos reales.
-- ---------------------------------------------------------------------
create table public.settings (
  id                              boolean primary key default true check (id),
  owner_user_id                   uuid references auth.users(id) on delete set null,
  business_name                   text,
  whatsapp_phone                  text check (whatsapp_phone is null or whatsapp_phone ~ '^[0-9]{8,15}$'),
  timezone                        text not null default 'America/Argentina/Buenos_Aires',
  booking_enabled                 boolean not null default false,
  auto_confirm                    boolean not null default true,
  slot_step_minutes               int  not null default 15  check (slot_step_minutes between 5 and 240),
  min_booking_notice_minutes      int  not null default 60  check (min_booking_notice_minutes >= 0),
  max_booking_days_ahead          int  not null default 30  check (max_booking_days_ahead between 1 and 365),
  allow_same_day                  boolean not null default true,
  min_cancel_notice_minutes       int  not null default 120 check (min_cancel_notice_minutes >= 0),
  min_reschedule_notice_minutes   int  not null default 120 check (min_reschedule_notice_minutes >= 0),
  max_active_appointments_per_phone int check (max_active_appointments_per_phone > 0), -- null = sin límite
  no_show_block_threshold         int check (no_show_block_threshold > 0),            -- null = nunca bloquear
  offers_mode                     text not null default 'approval'
                                  check (offers_mode in ('off', 'auto', 'approval')),
  offer_response_minutes          int  not null default 15  check (offer_response_minutes between 1 and 1440),
  offer_min_lead_minutes          int  not null default 60  check (offer_min_lead_minutes >= 0),
  proposal_response_hours         int  not null default 24  check (proposal_response_hours between 1 and 168),
  updated_at                      timestamptz not null default now()
);

comment on table public.settings is 'Configuración del negocio. Siempre una sola fila (id = true).';
comment on column public.settings.offers_mode is 'off: sin lista de espera · auto: las ofertas salen solas · approval: el peluquero aprueba cada oferta';
comment on column public.settings.offer_min_lead_minutes is 'Margen mínimo entre el vencimiento de una oferta y el horario ofrecido (tiempo para llegar).';

insert into public.settings default values;

-- Valida que la zona horaria exista
create function public._settings_validate() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  perform now() at time zone new.timezone;
  new.updated_at := now();
  return new;
exception when others then
  raise exception 'ZONA_HORARIA_INVALIDA' using detail = new.timezone;
end $$;

create trigger settings_validate before insert or update on public.settings
  for each row execute function public._settings_validate();

-- ---------------------------------------------------------------------
-- Servicios
-- ---------------------------------------------------------------------
create table public.services (
  id               uuid primary key default gen_random_uuid(),
  name             text not null check (length(btrim(name)) between 1 and 80),
  description      text check (description is null or length(description) <= 500),
  price            numeric(12, 2) not null check (price >= 0),
  duration_minutes int not null check (duration_minutes between 5 and 600),
  buffer_minutes   int not null default 0 check (buffer_minutes between 0 and 120),
  active           boolean not null default true,
  sort_order       int not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);
comment on column public.services.buffer_minutes is 'Tiempo extra libre después del servicio (limpieza, preparación).';

-- ---------------------------------------------------------------------
-- Horario de atención semanal
-- Varias franjas en un mismo día = descansos entre ellas.
-- weekday: 0 = domingo … 6 = sábado (igual que extract(dow)).
-- ---------------------------------------------------------------------
create table public.working_hours (
  id         uuid primary key default gen_random_uuid(),
  weekday    smallint not null check (weekday between 0 and 6),
  start_time time not null,
  end_time   time not null,
  check (start_time < end_time)
);
create index working_hours_weekday_idx on public.working_hours (weekday);

-- ---------------------------------------------------------------------
-- Clientes (identificados por teléfono, sólo dígitos con código de país)
-- ---------------------------------------------------------------------
create table public.customers (
  id         uuid primary key default gen_random_uuid(),
  name       text not null check (length(btrim(name)) between 2 and 80),
  phone      text not null unique check (phone ~ '^[0-9]{8,15}$'),
  email      text check (email is null or email ~* '^[^@\s]+@[^@\s]+\.[^@\s]+$'),
  notes      text check (notes is null or length(notes) <= 2000),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- Agenda: turnos, bloqueos y retenciones
-- ---------------------------------------------------------------------
create table public.agenda (
  id                uuid primary key default gen_random_uuid(),
  kind              text not null check (kind in ('appointment', 'block', 'hold')),
  status            text not null,
  period            tstzrange not null,           -- horario visible (servicio o bloqueo)
  buffer_minutes    int not null default 0 check (buffer_minutes >= 0),
  occupied          tstzrange not null,           -- period + tiempo extra; lo calcula un trigger
  customer_id       uuid references public.customers(id) on delete restrict,
  service_id        uuid references public.services(id) on delete restrict,
  -- copias al momento de reservar (las estadísticas no cambian si cambian los precios)
  service_name      text,
  price             numeric(12, 2),
  duration_minutes  int,
  wants_earlier     boolean not null default false,
  customer_note     text check (customer_note is null or length(customer_note) <= 500),
  admin_note        text check (admin_note is null or length(admin_note) <= 2000),
  source            text check (source in ('online', 'admin')),
  manage_token_hash bytea unique,
  hold_expires_at   timestamptz,
  reason            text check (reason is null or length(reason) <= 300),
  cancelled_at      timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint agenda_period_valid check (
    not isempty(period) and lower(period) is not null and upper(period) is not null
    and lower_inc(period) and not upper_inc(period)
  ),
  constraint agenda_kind_status check (
    (kind = 'appointment' and status in
      ('pending', 'confirmed', 'completed', 'no_show', 'cancelled_by_customer', 'cancelled_by_admin'))
    or (kind in ('block', 'hold') and status in ('active', 'released'))
  ),
  constraint agenda_appointment_fields check (
    kind <> 'appointment' or (
      customer_id is not null and service_id is not null and service_name is not null
      and price is not null and duration_minutes is not null and source is not null
    )
  ),
  constraint agenda_hold_expiry check (kind <> 'hold' or hold_expires_at is not null),

  -- LA regla: dos filas activas nunca se superponen.
  constraint agenda_no_overlap exclude using gist (occupied with &&)
    where (status in ('pending', 'confirmed', 'completed', 'no_show', 'active'))
);

create index agenda_lower_idx    on public.agenda (lower(period));
create index agenda_customer_idx on public.agenda (customer_id);
create index agenda_active_idx   on public.agenda (kind, status);

comment on table public.agenda is 'Todo lo que ocupa tiempo: turnos, bloqueos y retenciones. La restricción agenda_no_overlap impide superposiciones.';

create function public._agenda_compute() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin
  new.occupied   := tstzrange(lower(new.period),
                              upper(new.period) + make_interval(mins => new.buffer_minutes), '[)');
  new.updated_at := now();
  return new;
end $$;

create trigger agenda_compute before insert or update of period, buffer_minutes, status
  on public.agenda for each row execute function public._agenda_compute();

-- ---------------------------------------------------------------------
-- Lista de espera: horarios liberados y ofertas
-- ---------------------------------------------------------------------
create table public.freed_slots (
  id                    uuid primary key default gen_random_uuid(),
  start_at              timestamptz not null,
  local_day             date not null,
  origin_appointment_id uuid references public.agenda(id) on delete set null,
  status                text not null default 'open'
                        check (status in ('open', 'offering', 'filled', 'exhausted')),
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);
create index freed_slots_status_idx on public.freed_slots (status);

create table public.offers (
  id               uuid primary key default gen_random_uuid(),
  kind             text not null check (kind in ('advance', 'proposal')),
  appointment_id   uuid not null references public.agenda(id) on delete cascade,
  freed_slot_id    uuid references public.freed_slots(id) on delete set null,
  original_period  tstzrange not null,
  proposed_period  tstzrange not null,
  hold_id          uuid references public.agenda(id) on delete set null,
  status           text not null check (status in
                   ('pending_approval', 'sent', 'accepted', 'declined', 'expired', 'cancelled')),
  token_hash       bytea unique,
  expires_at       timestamptz not null,
  has_push         boolean not null default false,
  created_at       timestamptz not null default now(),
  sent_at          timestamptz,
  responded_at     timestamptz,
  constraint offers_kind_slot check (kind <> 'advance' or freed_slot_id is not null)
);
-- Un turno no puede tener dos ofertas abiertas a la vez
create unique index offers_one_open_per_appointment on public.offers (appointment_id)
  where status in ('pending_approval', 'sent');
create index offers_status_idx on public.offers (status, expires_at);
create index offers_freed_slot_idx on public.offers (freed_slot_id);

comment on column public.offers.kind is 'advance: adelantar a un horario liberado · proposal: el peluquero propone otro horario';

-- ---------------------------------------------------------------------
-- Notificaciones push
-- ---------------------------------------------------------------------
create table public.push_subscriptions (
  id          uuid primary key default gen_random_uuid(),
  customer_id uuid not null references public.customers(id) on delete cascade,
  endpoint    text not null unique,
  p256dh      text not null,
  auth        text not null,
  created_at  timestamptz not null default now()
);

-- Cola que vacía la Edge Function de envío de push (Etapa 4).
-- `url` puede contener un enlace privado: se borra al enviarse.
create table public.notification_queue (
  id          bigint generated always as identity primary key,
  customer_id uuid not null references public.customers(id) on delete cascade,
  offer_id    uuid references public.offers(id) on delete set null,
  kind        text not null,
  title       text not null,
  body        text not null,
  url         text,
  created_at  timestamptz not null default now(),
  sent_at     timestamptz,
  attempts    int not null default 0,
  last_error  text
);
create index notification_queue_pending_idx on public.notification_queue (created_at) where sent_at is null;

-- ---------------------------------------------------------------------
-- Cobros (registro manual, opcional)
-- ---------------------------------------------------------------------
create table public.payments (
  id             uuid primary key default gen_random_uuid(),
  appointment_id uuid references public.agenda(id) on delete set null,
  amount         numeric(12, 2) not null check (amount > 0),
  method         text not null check (length(btrim(method)) between 1 and 40),
  paid_at        timestamptz not null default now(),
  note           text check (note is null or length(note) <= 500)
);
create index payments_paid_at_idx on public.payments (paid_at);

-- ---------------------------------------------------------------------
-- Historial de cambios de la agenda
-- ---------------------------------------------------------------------
create table public.events (
  id         bigint generated always as identity primary key,
  agenda_id  uuid,
  actor      text not null,
  action     text not null,
  detail     jsonb,
  created_at timestamptz not null default now()
);
create index events_agenda_idx on public.events (agenda_id);

create function public._agenda_log() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_actor text := coalesce(nullif(current_setting('app.actor', true), ''), 'system');
begin
  if tg_op = 'INSERT' then
    insert into events (agenda_id, actor, action, detail)
    values (new.id, v_actor, 'created',
            jsonb_build_object('kind', new.kind, 'status', new.status,
                               'start', lower(new.period), 'end', upper(new.period)));
  elsif new.status is distinct from old.status or new.period is distinct from old.period then
    insert into events (agenda_id, actor, action, detail)
    values (new.id, v_actor,
            case when new.status is distinct from old.status then 'status_changed' else 'moved' end,
            jsonb_build_object('kind', new.kind,
                               'from_status', old.status, 'to_status', new.status,
                               'from_start', lower(old.period), 'to_start', lower(new.period)));
  end if;
  return null;
end $$;

create trigger agenda_log after insert or update on public.agenda
  for each row execute function public._agenda_log();

-- updated_at genérico
create function public._touch() returns trigger
language plpgsql set search_path = public, pg_temp as $$
begin new.updated_at := now(); return new; end $$;

create trigger services_touch    before update on public.services    for each row execute function public._touch();
create trigger customers_touch   before update on public.customers   for each row execute function public._touch();
create trigger freed_slots_touch before update on public.freed_slots for each row execute function public._touch();
