-- =====================================================================
-- 05b · Panel de la plataforma (dueño de la app)
-- Ver peluquerías, activarlas por un período pago, suspenderlas.
-- Una peluquería con paid_until vencido deja de aceptar reservas sola.
-- =====================================================================

create table public.platform_settings (
  id      boolean primary key default true check (id),
  app_url text check (app_url is null or app_url ~ '^https://[^\s]+[^/]$')
);
comment on column public.platform_settings.app_url is 'Dirección base de la app, sin barra final (p. ej. https://turnos.pages.dev). Cada peluquería queda en app_url/<slug>.';
insert into public.platform_settings default values;

create function public.super_peluquerias()
returns table (
  id uuid, slug text, nombre text, email text, whatsapp text, estado text, vence date,
  activa boolean, servicios int, turnos_ultimos_30_dias int, registrada timestamptz
)
language plpgsql stable security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  return query
    select s.id, s.slug, s.business_name, u.email::text, s.whatsapp_phone, s.status, s.paid_until,
           public._shop_active(s),
           (select count(*)::int from services sv where sv.shop_id = s.id and sv.active),
           (select count(*)::int from agenda a where a.shop_id = s.id and a.kind = 'appointment'
                                                and a.created_at > now() - interval '30 days'),
           s.created_at
      from shops s left join auth.users u on u.id = s.owner_user_id
     order by (s.status = 'pending') desc, s.paid_until nulls first, s.created_at desc;
end $$;

-- Activa (o renueva) una peluquería hasta una fecha. Sin fecha: un mes desde
-- hoy, o desde el vencimiento actual si todavía no venció.
create function public.super_activar(
  p_shop_id uuid, p_hasta date default null, p_monto numeric default null, p_nota text default null
) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
declare
  s       public.shops;
  v_today date;
  v_from  date;
  v_until date;
begin
  perform public._require_platform_admin();
  select * into s from shops where id = p_shop_id for update;
  if not found then raise exception 'PELUQUERIA_INEXISTENTE'; end if;

  v_today := (now() at time zone s.timezone)::date;
  v_from  := greatest(v_today, coalesce(s.paid_until + 1, v_today));
  v_until := coalesce(p_hasta, (v_from + interval '1 month')::date - 1);
  if v_until < v_today then raise exception 'FECHA_INVALIDA'; end if;

  update shops set status = 'active', paid_until = v_until where id = s.id;
  insert into subscription_payments (shop_id, amount, paid_from, paid_until, note, created_by)
  values (s.id, p_monto, v_from, v_until, p_nota, auth.uid());

  return jsonb_build_object('slug', s.slug, 'estado', 'active', 'vence', v_until);
end $$;

create function public.super_suspender(p_shop_id uuid) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  update shops set status = 'suspended' where id = p_shop_id;
  if not found then raise exception 'PELUQUERIA_INEXISTENTE'; end if;
  return jsonb_build_object('estado', 'suspended');
end $$;

-- Configura la dirección base de la app (una vez)
create function public.super_configurar(p_app_url text) returns jsonb
language plpgsql volatile security definer set search_path = public, pg_temp as $$
begin
  perform public._require_platform_admin();
  update platform_settings set app_url = p_app_url where id;
  return jsonb_build_object('app_url', p_app_url);
end $$;

-- Consulta mínima a la base (la usa el workflow que evita la pausa del plan gratuito)
create function public.ping() returns boolean
language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from platform_settings)
$$;
