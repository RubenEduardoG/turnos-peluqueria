-- Pruebas de flujos completos (plataforma con varias peluquerías).
-- Ejecutar sobre una base con 00_simular_supabase.sql y las migraciones aplicadas
-- (menos pg_cron). Termina con error ante el primer fallo.
-- Servicios, horarios y nombres son DATOS DE PRUEBA.
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\set ROOT 'reset role;'
\set ANON 'reset role; set request.jwt.claims to ''''; set role anon;'
\set SUPER 'reset role; set request.jwt.claims to ''{"sub":"00000000-0000-0000-0000-000000000001"}''; set role authenticated;'
\set ADMIN 'reset role; set request.jwt.claims to ''{"sub":"00000000-0000-0000-0000-00000000a001"}''; set role authenticated;'
\set ADMINB 'reset role; set request.jwt.claims to ''{"sub":"00000000-0000-0000-0000-00000000b002"}''; set role authenticated;'
\set OTRO 'reset role; set request.jwt.claims to ''{"sub":"00000000-0000-0000-0000-00000000c003"}''; set role authenticated;'

-- ---------- utilidades ----------
create function public.t_ok(c boolean, m text) returns void language plpgsql as $$
begin
  if not coalesce(c, false) then raise exception 'FALLO: %', m; end if;
  raise notice 'OK  %', m;
end $$;
create function public.t_err(p_sql text, p_expect text, m text) returns void language plpgsql as $$
begin
  begin
    execute p_sql;
  exception when others then
    if position(p_expect in sqlerrm) > 0 then raise notice 'OK  % (error %)', m, p_expect; return; end if;
    raise exception 'FALLO: % → se esperaba % y vino: %', m, p_expect, sqlerrm;
  end;
  raise exception 'FALLO: % → se esperaba el error %', m, p_expect;
end $$;
create function public.t_at(p_hora text, p_dias int) returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/Argentina/Buenos_Aires')::date + p_dias) + p_hora::time)
         at time zone 'America/Argentina/Buenos_Aires'
$$;
create function public.t_d(p_dias int) returns date language sql stable as $$
  select (now() at time zone 'America/Argentina/Buenos_Aires')::date + p_dias
$$;
-- horarios libres de un servicio, día hoy + p_dias
create function public.t_h(p_svc uuid, p_dias int, p_slug text default 'barberia-a') returns setof timestamptz
language sql stable as $$ select * from public.horarios_disponibles(p_slug, p_svc, public.t_d(p_dias)) $$;
grant execute on function public.t_ok(boolean, text), public.t_err(text, text, text), public.t_at(text, int),
  public.t_d(int), public.t_h(uuid, int, text) to anon, authenticated;

\set S60 '''00000000-0000-0000-0000-000000000060'''
\set S30 '''00000000-0000-0000-0000-000000000030'''
\set S6015 '''00000000-0000-0000-0000-000000000061'''
\set S90 '''00000000-0000-0000-0000-000000000090'''
\set SB '''00000000-0000-0000-0000-0000000000b1'''

insert into auth.users values
  ('00000000-0000-0000-0000-000000000001', 'duenio@plataforma.test'),
  ('00000000-0000-0000-0000-00000000a001', 'peluquero.a@test'),
  ('00000000-0000-0000-0000-00000000b002', 'peluquero.b@test'),
  ('00000000-0000-0000-0000-00000000c003', 'otro@test');
insert into platform_admins values ('00000000-0000-0000-0000-000000000001');

\echo '--- 1. Registro de peluquerías y aprobación'
:ADMIN
select t_ok((registrar_peluqueria('barberia-a', 'Barbería A', '+54 9 11 0000-0000') ->> 'estado') = 'pending',
            'el peluquero A se registra: queda pendiente');
select t_err('select registrar_peluqueria(''otra'', ''Otra'')', 'YA_TENES_PELUQUERIA', 'una sola peluquería por cuenta');
-- el peluquero carga su configuración, servicios y horarios (por RLS, sin poner shop_id)
update shops set slot_step_minutes = 30, min_booking_notice_minutes = 60, max_booking_days_ahead = 30,
       min_cancel_notice_minutes = 120, min_reschedule_notice_minutes = 120,
       offer_response_minutes = 15, offer_min_lead_minutes = 60, booking_enabled = true;
insert into services (id, name, price, duration_minutes, buffer_minutes) values
  (:S60, 'Servicio 60', 1000, 60, 0), (:S30, 'Servicio 30', 500, 30, 0),
  (:S6015, 'Servicio 60 + 15 extra', 1200, 60, 15), (:S90, 'Servicio 90', 1500, 90, 0);
insert into working_hours (weekday, start_time, end_time)
  select d, time '09:00', time '13:00' from generate_series(0, 6) d
  union all select d, time '14:00', time '20:00' from generate_series(0, 6) d;
select t_ok((select count(*) from message_templates) = 5, 'al registrarse recibe 5 mensajes listos');
select t_err('update shops set status = ''active''', 'permission denied', 'el peluquero no puede activarse solo');
select t_err('update shops set paid_until = current_date + 365', 'permission denied', 'ni extender su vencimiento');
:ANON
select t_err('select info_negocio(''barberia-a'')', 'PELUQUERIA_INEXISTENTE', 'una peluquería pendiente no es pública');
select t_ok((select count(*) from t_h(:S60, 2)) = 0, 'pendiente: no muestra horarios');
:OTRO
select t_err('select registrar_peluqueria(''barberia-a'', ''Copia'')', 'DIRECCION_EN_USO', 'la dirección ya está tomada');
select t_err('select registrar_peluqueria(''admin'', ''Admin'')', 'DIRECCION_RESERVADA', 'direcciones reservadas');
select t_err('select super_peluquerias()', 'NO_AUTORIZADO', 'un usuario común no ve el panel de la plataforma');
:SUPER
select super_configurar('https://prueba.pages.dev') is not null as x \gset
select t_ok((select estado from super_peluquerias() where slug = 'barberia-a') = 'pending', 'el dueño ve la solicitud pendiente');
select t_ok((super_activar((select id from super_peluquerias() where slug = 'barberia-a')) ->> 'vence')::date
            = (t_d(0) + interval '1 month')::date - 1, 'activa A por un mes');
:ANON
select t_ok((info_negocio('barberia-a') ->> 'reservas_habilitadas')::boolean, 'activa: A acepta reservas');

\echo '--- 2. Seguridad'
select t_err('select * from agenda', 'permission denied', 'anon no lee la agenda');
select t_err('select * from shops', 'permission denied', 'anon no lee peluquerías');
select t_err('select admin_estadisticas(current_date, current_date)', 'permission denied', 'anon no usa el panel');
select t_err('select _offer_next(null)', 'permission denied', 'anon no usa funciones internas');
select t_err('select super_peluquerias()', 'permission denied', 'anon no usa el panel de la plataforma');

\echo '--- 3. Disponibilidad'
select t_ok((select count(*) from t_h(:S60, 2)) = 18, '18 horarios de 60 min (9–13 y 14–20, cada 30 min)');
select t_ok(not exists (select 1 from t_h(:S60, 2) h where h = t_at('12:30', 2)), '60 min no puede empezar 12:30 (descanso)');
select t_ok((select count(*) from t_h(:S60, 40)) = 0, 'no más allá del límite de días');
select t_err('select info_negocio(''no-existe'')', 'PELUQUERIA_INEXISTENTE', 'dirección inexistente');

\echo '--- 4. Reservas del ejemplo (día +2)'
select reservar('barberia-a', :S60, t_at('10:00', 2), 'Lucas',   '5491100000001', null, null, true) ->> 'token' as tok_lucas \gset
select reservar('barberia-a', :S60, t_at('11:00', 2), 'Martín',  '5491100000002', null, null, true) ->> 'token' as tok_martin \gset
select reservar('barberia-a', :S60, t_at('12:00', 2), 'Facundo', '5491100000003', null, null, true) ->> 'token' as tok_facundo \gset
select reservar('barberia-a', :S60, t_at('14:00', 2), 'Juan',    '5491100000004', null, null, true) ->> 'token' as tok_juan \gset
select reservar('barberia-a', :S60, t_at('15:00', 2), 'Nicolás', '5491100000005', null, null, true) ->> 'token' as tok_nico \gset
select t_ok((select count(*) from mis_turnos(array[:'tok_facundo'])) = 1, 'Facundo ve su turno con su enlace');
select t_ok((select slug from mis_turnos(array[:'tok_facundo'])) = 'barberia-a', 'y de qué peluquería es');
select t_ok((select count(*) from mis_turnos(array['enlace-falso'])) = 0, 'un enlace falso no muestra nada');
select t_err(format('select reservar(''barberia-a'', %L, %L, ''Otro'', ''5491100000099'', null, null, true)', :S60, t_at('10:00', 2)),
             'HORARIO_NO_DISPONIBLE', 'no se reserva un horario ocupado');
select t_err(format('select reservar(''barberia-a'', %L, %L, ''Otro'', ''5491100000099'', null, null, true)', :S60, t_at('10:30', 2)),
             'HORARIO_NO_DISPONIBLE', 'ni uno que se superpone');
select t_err(format('select reservar(''barberia-a'', %L, %L, ''Otro'', ''5491100000099'', null, null, false)', :S60, t_at('16:00', 2)),
             'FALTA_CONSENTIMIENTO', 'hace falta aceptar el aviso de privacidad');
select t_err(format('select reservar(''barberia-a'', %L, %L, ''Otro'', ''123'', null, null, true)', :S60, t_at('16:00', 2)),
             'TELEFONO_INVALIDO', 'teléfono inválido');

\echo '--- 5. Notificaciones y "avisarme si se libera antes"'
select registrar_push(:'tok_facundo', 'https://push.example/facundo', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select registrar_push(:'tok_juan', 'https://push.example/juan', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select t_err(format('select preferencia_adelanto(%L, true)', :'tok_lucas'), 'NECESITA_NOTIFICACIONES',
             'sin notificaciones no se activa el aviso de adelanto');
select preferencia_adelanto(:'tok_facundo', true) is not null as x \gset
select preferencia_adelanto(:'tok_juan', true) is not null as x \gset

\echo '--- 6. Martín cancela → la oferta de las 11:00 le llega sola a Facundo'
select cancelar_turno(:'tok_martin') is not null as x \gset
:ROOT
select t_ok((select count(*) from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
             where c.name = 'Facundo' and o.status = 'sent' and lower(o.proposed_period) = t_at('11:00', 2)) = 1,
            'oferta para Facundo a las 11:00, sin aprobación');
select t_ok((select count(*) from agenda where kind = 'hold' and status = 'active' and lower(period) = t_at('11:00', 2)) = 1,
            'el hueco queda retenido');
:ANON
select t_ok(not exists (select 1 from t_h(:S30, 2) h where h = t_at('11:00', 2)), 'nadie más reserva las 11:00 mientras se ofrece');

\echo '--- 7. Facundo acepta → cascada a Juan'
:ROOT
select split_part(q.url, '#', 2) as tok_of_facundo from notification_queue q join customers c on c.id = q.customer_id
 where c.name = 'Facundo' and q.kind = 'advance' \gset
select t_ok((select url from notification_queue q join customers c on c.id = q.customer_id
             where c.name = 'Facundo' and q.kind = 'advance') like '/barberia-a/oferta#%', 'el enlace incluye la peluquería');
:ANON
select t_ok((ver_oferta(:'tok_of_facundo') ->> 'estado') = 'sent', 'Facundo ve la oferta');
select t_ok((responder_oferta(:'tok_of_facundo', true) ->> 'result') = 'aceptada', 'Facundo acepta');
select t_ok((select inicio from mis_turnos(array[:'tok_facundo'])) = t_at('11:00', 2), 'Facundo pasó a las 11:00');
:ROOT
select t_ok((select count(*) from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
             where c.name = 'Juan' and o.status = 'sent' and lower(o.proposed_period) = t_at('12:00', 2)) = 1,
            'cascada: las 12:00 le llegan a Juan');

\echo '--- 8. Juan rechaza → Nicolás; vence → el hueco vuelve al público'
:ANON
select registrar_push(:'tok_nico', 'https://push.example/nico', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select preferencia_adelanto(:'tok_nico', true) is not null as x \gset
select t_ok((select oferta ->> 'tipo' from mis_turnos(array[:'tok_juan'])) = 'advance', 'Juan ve la oferta en Mis turnos');
select t_ok((responder_oferta_de_mi_turno(:'tok_juan', false) ->> 'result') = 'rechazada', 'Juan rechaza');
select t_ok((select inicio from mis_turnos(array[:'tok_juan'])) = t_at('14:00', 2), 'Juan conserva las 14:00');
:ROOT
select t_ok((select count(*) from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
             where c.name = 'Nicolás' and o.status = 'sent') = 1, 'ahora se le ofrece a Nicolás');
update offers set expires_at = now() - interval '1 second' where status = 'sent';
select t_ok(_procesar_vencimientos() = 1, 'la tarea programada vence la oferta');
select t_ok((select status from freed_slots order by created_at desc limit 1) = 'exhausted', 'sin más candidatos, se cierra');
:ANON
select t_ok(exists (select 1 from t_h(:S60, 2) h where h = t_at('12:00', 2)), 'las 12:00 vuelven al público');

\echo '--- 9. Propuesta del peluquero'
:ADMIN
select admin_proponer_horario((select a.id from agenda a join customers c on c.id = a.customer_id where c.name = 'Lucas'),
                              t_at('16:00', 2)) ->> 'token_oferta' as tok_prop \gset
:ANON
select t_ok((select inicio from mis_turnos(array[:'tok_lucas'])) = t_at('10:00', 2), 'mientras decide, Lucas sigue a las 10:00');
select t_ok(not exists (select 1 from t_h(:S60, 2) h where h = t_at('16:00', 2)), 'las 16:00 quedan retenidas');
select t_ok((responder_oferta(:'tok_prop', true) ->> 'result') = 'aceptada', 'Lucas acepta');
select t_ok((select inicio from mis_turnos(array[:'tok_lucas'])) = t_at('16:00', 2), 'Lucas pasó a las 16:00');
select t_ok((responder_oferta(:'tok_prop', true) ->> 'result') = 'no_disponible', 'una oferta no se usa dos veces');

\echo '--- 10. El cliente cambia su horario solo'
select t_ok((reprogramar_turno(:'tok_nico', t_at('17:00', 2)) ->> 'inicio')::timestamptz = t_at('17:00', 2), 'Nicolás pasa de 15:00 a 17:00');
:ROOT
select t_ok(not exists (select 1 from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
                        where c.name = 'Nicolás' and o.status in ('pending_approval', 'sent')),
            'no se le ofrece el horario que acaba de dejar');
:ANON
select t_err(format('select reprogramar_turno(%L, %L)', :'tok_nico', t_at('16:00', 2)), 'HORARIO_NO_DISPONIBLE',
             'no se mueve a un horario ocupado');

\echo '--- 11. Bloqueos'
:ADMIN
select t_err(format('select admin_bloquear(%L, %L, ''Imprevisto'')', t_at('13:30', 2), t_at('15:00', 2)),
             'HAY_TURNOS_EN_CONFLICTO', 'bloquear sobre turnos avisa del conflicto');
select t_ok(jsonb_array_length(admin_bloquear_resto_jornada(t_at('13:30', 2), 'Imprevisto', true) -> 'turnos_cancelados') = 3,
            'bloquear el resto de la jornada cancela 3 turnos y los devuelve');
:ANON
select t_ok((select count(*) from t_h(:S30, 2) h where h >= t_at('13:30', 2)) = 0, 'esa tarde no hay horarios');
:ADMIN
select t_ok((admin_bloquear_dias(t_d(5), t_d(7), 'Vacaciones') ->> 'bloqueo_id') is not null, 'vacaciones de 3 días');
:ANON
select t_ok((select sum(horarios) from dias_disponibles('barberia-a', :S60, t_d(5), t_d(7))) = 0, 'en vacaciones no hay horarios');

\echo '--- 12. Tiempo extra entre turnos'
select reservar('barberia-a', :S6015, t_at('16:00', 3), 'Ana', '5491100000006', null, null, true) ->> 'token' as tok_ana \gset
select t_ok(not exists (select 1 from t_h(:S30, 3) h where h = t_at('17:00', 3)), '17:00 ocupado por el tiempo extra');
select t_ok(exists (select 1 from t_h(:S30, 3) h where h = t_at('17:30', 3)), '17:30 libre');

\echo '--- 13. Plazos y estados'
:ADMIN
select admin_crear_turno('Pedro', '5491100000007', :S30, date_trunc('minute', now()) + interval '90 minutes', null, true) ->> 'token' as tok_pedro \gset
:ANON
select t_err(format('select cancelar_turno(%L)', :'tok_pedro'), 'FUERA_DE_PLAZO_CANCELACION', 'no se cancela con menos de 2 h');
:ADMIN
select t_err(format('select admin_marcar_turno(%L, ''completed'')',
                    (select id from agenda where service_name = 'Servicio 30' and source = 'admin' limit 1)),
             'TURNO_AUN_NO_EMPEZO', 'no se marca realizado antes de empezar');
select t_err(format('select admin_crear_turno(''Xavier'', ''5491100000008'', %L, %L)', :S30, t_at('11:00', 2)),
             'HORARIO_OCUPADO', 'el peluquero tampoco puede superponer turnos');

\echo '--- 14. Adelanto con servicio largo (y modo con aprobación)'
:ADMIN
update shops set offers_mode = 'approval';
:ANON
select reservar('barberia-a', :S30, t_at('10:30', 4), 'Bruno', '5491100000010', null, null, true) ->> 'token' as tok_bruno \gset
select reservar('barberia-a', :S90, t_at('11:00', 4), 'Carla', '5491100000011', null, null, true) ->> 'token' as tok_carla \gset
select registrar_push(:'tok_carla', 'https://push.example/carla', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select preferencia_adelanto(:'tok_carla', true) is not null as x \gset
select cancelar_turno(:'tok_bruno') is not null as x \gset
:ROOT
select t_ok((select upper(period) from agenda where kind = 'hold' and status = 'active' and lower(period) = t_at('10:30', 4)) = t_at('11:00', 4),
            'se retiene sólo 10:30–11:00');
:ADMIN
select admin_aprobar_oferta((select id from offers where status = 'pending_approval')) ->> 'token_oferta' as tok_of_carla \gset
:ANON
select t_ok((responder_oferta(:'tok_of_carla', true) ->> 'result') = 'aceptada', 'Carla (90 min) adelanta a 10:30');
select t_ok((select fin from mis_turnos(array[:'tok_carla'])) = t_at('12:00', 4), 'Carla queda 10:30–12:00');
:ADMIN
update shops set offers_mode = 'auto';

\echo '--- 15. Avisos al peluquero'
select admin_registrar_push('https://push.example/admin-a', repeat('k', 40), repeat('a', 16)) is not null as x \gset
:ANON
select reservar('barberia-a', :S30, t_at('10:00', 3), 'Diego', '5491100000012', null, null, true) ->> 'token' as tok_diego \gset
select reservar('barberia-a', :S30, t_at('11:00', 3), 'Eva',   '5491100000013', null, null, true) ->> 'token' as tok_eva \gset
select registrar_push(:'tok_eva', 'https://push.example/eva', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select reprogramar_turno(:'tok_diego', t_at('09:30', 3)) is not null as x \gset
:ADMIN
select t_ok((select count(*) from notification_queue where to_admin and title = 'Nueva reserva' and body like 'Diego · Servicio 30 · %') = 1,
            'al peluquero le llega "Nueva reserva"');
select t_ok((select count(*) from notification_queue where to_admin and title = 'Turno cambiado' and body like 'Diego pasó del %') = 1,
            'y "Turno cambiado", sin aprobar nada');

\echo '--- 16. Panel de cancelación'
select t_ok(jsonb_array_length(admin_cancelar_y_avisar(t_at('09:00', 3), t_at('13:00', 3), 'elegir_otro',
              (select id from message_templates where title = 'Imprevisto')) -> 'afectados') = 2, 'vista previa: Diego y Eva');
select t_ok((select count(*) from agenda where status = 'confirmed' and lower(period) between t_at('09:00', 3) and t_at('12:00', 3)) = 2,
            'la vista previa no cambia nada');
select admin_cancelar_y_avisar(t_at('09:00', 3), t_at('13:00', 3), 'elegir_otro',
         (select id from message_templates where title = 'Imprevisto'), null, 'Imprevisto', true) as res \gset
select t_ok((:'res'::jsonb -> 'afectados' -> 0 ->> 'mensaje') like 'Hola Diego, ¿cómo estás? Te escribo porque por un imprevisto no voy a poder atenderte el % a las 09:30.%Elegí otro horario acá: https://prueba.pages.dev/barberia-a/turno#%',
            'mensaje personal con la dirección de su peluquería');
select t_ok((:'res'::jsonb -> 'afectados' -> 0 ->> 'whatsapp_url') like 'https://wa.me/5491100000012?text=Hola%20Diego%', 'botón de WhatsApp armado');
select t_ok((:'res'::jsonb -> 'afectados' -> 1 ->> 'tiene_push')::boolean, 'a Eva además le llega por notificación');
select substring(:'res'::jsonb -> 'afectados' -> 0 ->> 'mensaje' from '/turno#([0-9a-f]{64})') as tok_diego2 \gset
:ANON
select t_ok((select count(*) from mis_turnos(array[:'tok_diego'])) = 0, 'el enlace viejo deja de valer');
select t_ok((select debe_elegir_horario from mis_turnos(array[:'tok_diego2'])), 'con el nuevo, Diego ve que tiene que elegir');
select t_ok((reprogramar_turno(:'tok_diego2', t_at('14:00', 3)) ->> 'inicio')::timestamptz = t_at('14:00', 3), 'elige las 14:00');
select t_ok((select estado from mis_turnos(array[:'tok_diego2'])) = 'confirmed', 'vuelve a estar confirmado');
:ADMIN
select admin_cancelar_y_avisar(t_at('09:00', 4), t_at('13:00', 4), 'solo_avisar', null,
         'Hola {nombre}, hoy no abro. Tu turno del {dia} a las {hora} queda cancelado. {enlace}', 'Cierre', true)
       -> 'afectados' -> 0 ->> 'mensaje' as msg_carla \gset
select t_ok(:'msg_carla' like 'Hola Carla, hoy no abro.%Cuando quieras, reservá de nuevo acá: https://prueba.pages.dev/barberia-a',
            'mensaje propio, opción sólo avisar');
:ANON
select t_ok((select estado from mis_turnos(array[:'tok_carla'])) = 'cancelled_by_admin', 'Carla lo ve cancelado');
select t_err(format('select reprogramar_turno(%L, %L)', :'tok_carla', t_at('15:00', 4)), 'TURNO_NO_MODIFICABLE', 'y no puede reubicarlo');

\echo '--- 17. Segunda peluquería: aislamiento total'
:ADMINB
select registrar_peluqueria('barberia-b', 'Barbería B') is not null as x \gset
update shops set slot_step_minutes = 30, booking_enabled = true, max_booking_days_ahead = 30;
insert into services (id, name, price, duration_minutes) values (:SB, 'Corte B', 800, 60);
insert into working_hours (weekday, start_time, end_time) select d, time '09:00', time '20:00' from generate_series(0, 6) d;
:SUPER
select super_activar((select id from super_peluquerias() where slug = 'barberia-b'), t_d(10), 15000, 'Transferencia') is not null as x \gset
:ANON
select reservar('barberia-b', :SB, t_at('10:00', 8), 'Lucas', '5491100000001', null, null, true) ->> 'token' as tok_lucas_b \gset
select reservar('barberia-a', :S60, t_at('10:00', 8), 'Lucas', '5491100000001', null, null, true) ->> 'token' as tok_lucas_a8 \gset
select t_ok(:'tok_lucas_a8' is not null, 'el mismo horario se reserva en las dos peluquerías (agendas separadas)');
select t_err(format('select reservar(''barberia-b'', %L, %L, ''X Y'', ''5491100000077'', null, null, true)', :S60, t_at('12:00', 8)),
             'SERVICIO_NO_DISPONIBLE', 'no se reserva en B un servicio de A');
select t_ok((select count(*) from t_h(:S60, 8, 'barberia-b')) = 0, 'B no muestra horarios de servicios de A');
:ADMINB
select t_ok((select count(*) from agenda) = 1, 'B ve sólo su turno');
select t_ok((select count(*) from customers) = 1, 'B ve sólo su cliente (Lucas en B es otro cliente)');
select t_ok((select count(*) from services) = 1 and (select count(*) from shops) = 1, 'B ve sólo sus servicios y su peluquería');
select t_err(format('select admin_cancelar_turno(''%s'')', (select '00000000-0000-0000-0000-000000000000')), 'TURNO_INEXISTENTE', 'control de turno inexistente');
:ROOT
select (select a.id from agenda a join shops s on s.id = a.shop_id where s.slug = 'barberia-a' and a.kind = 'appointment' and a.status = 'confirmed' limit 1) as turno_a \gset
:ADMINB
select t_err(format('select admin_cancelar_turno(%L)', :'turno_a'), 'TURNO_INEXISTENTE', 'B no puede cancelar un turno de A');
select t_err(format('select admin_proponer_horario(%L, %L)', :'turno_a', t_at('15:00', 9)), 'TURNO_INEXISTENTE', 'ni proponerle horario');
update agenda set admin_note = 'hackeo' where id = :'turno_a';
:ROOT
select t_ok((select admin_note from agenda where id = :'turno_a') is null, 'el update de B sobre un turno de A no afecta nada');
:ADMINB
select t_err(format('insert into services (shop_id, name, price, duration_minutes) values (%L, ''Intruso'', 1, 30)',
                    (select '00000000-0000-0000-0000-000000000000')), 'row-level security', 'B no puede crear servicios en otra peluquería');
select t_err('select super_activar(my_shop_id())', 'NO_AUTORIZADO', 'un peluquero no puede activarse con funciones de la plataforma');

\echo '--- 18. Vencimiento y suspensión'
:ROOT
update shops set paid_until = t_d(-1) where slug = 'barberia-b';
:ANON
select t_ok(not (info_negocio('barberia-b') ->> 'reservas_habilitadas')::boolean, 'B con el pago vencido deja de tomar reservas');
select t_err(format('select reservar(''barberia-b'', %L, %L, ''Ana'', ''5491100000020'', null, null, true)', :SB, t_at('15:00', 8)),
             'RESERVAS_DESHABILITADAS', 'reservar en B vencida falla');
select t_ok((select count(*) from mis_turnos(array[:'tok_lucas_b'])) = 1, 'los clientes de B siguen viendo sus turnos');
:SUPER
select t_ok((super_activar((select id from super_peluquerias() where slug = 'barberia-b')) ->> 'vence')::date
            = (t_d(0) + interval '1 month')::date - 1, 'al renovar, vence en un mes desde hoy');
:ADMINB
select t_ok((select count(*) from subscription_payments) = 2, 'B ve sus 2 pagos a la plataforma');
:SUPER
select super_suspender((select id from super_peluquerias() where slug = 'barberia-b')) is not null as x \gset
select t_ok((select not activa from super_peluquerias() where slug = 'barberia-b'), 'suspendida');
:ANON
select t_ok(not (info_negocio('barberia-b') ->> 'reservas_habilitadas')::boolean, 'B suspendida no toma reservas');
select t_ok((info_negocio('barberia-a') ->> 'reservas_habilitadas')::boolean, 'A sigue funcionando');

\echo '--- 19. Reservas hasta 5 días'
:ADMIN
update shops set max_booking_days_ahead = 5;
:ANON
select t_ok((select count(*) from t_h(:S30, 6)) = 0 and (select count(*) from t_h(:S30, 4)) > 0, 'con 5 días: +4 sí, +6 no');
:ADMIN
update shops set max_booking_days_ahead = 30;
select t_ok((admin_estadisticas(t_d(0), t_d(30)) ->> 'total')::int >= 8, 'estadísticas de A');

:ROOT
\echo '--- Todas las pruebas de flujos pasaron'
