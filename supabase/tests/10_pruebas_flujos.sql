-- Pruebas de flujos completos. Ejecutar sobre una base con 00_simular_supabase.sql
-- y las migraciones 01–06 aplicadas. Termina con error ante el primer fallo.
-- Los servicios, horarios y nombres son DATOS DE PRUEBA, no del negocio.
\set ON_ERROR_STOP 1
\set QUIET 1
\pset tuples_only on
\set ROOT 'reset role;'
\set ANON 'reset role; set request.jwt.claims to ''''; set role anon;'
\set ADMIN 'reset role; set request.jwt.claims to ''{"sub":"00000000-0000-0000-0000-00000000a001"}''; set role authenticated;'
\set OTRO 'reset role; set request.jwt.claims to ''{"sub":"00000000-0000-0000-0000-00000000b002"}''; set role authenticated;'

-- ---------- utilidades de prueba ----------
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
-- hora local del día (hoy + p_dias)
create function public.t_at(p_hora text, p_dias int) returns timestamptz language sql stable as $$
  select (((now() at time zone 'America/Argentina/Buenos_Aires')::date + p_dias) + p_hora::time)
         at time zone 'America/Argentina/Buenos_Aires'
$$;
grant execute on function public.t_ok(boolean, text), public.t_err(text, text, text), public.t_at(text, int)
  to anon, authenticated;

-- ---------- datos de prueba ----------
insert into auth.users values ('00000000-0000-0000-0000-00000000a001'), ('00000000-0000-0000-0000-00000000b002');
update settings set owner_user_id = '00000000-0000-0000-0000-00000000a001', business_name = 'Prueba',
       booking_enabled = true, offers_mode = 'auto', slot_step_minutes = 30,
       min_booking_notice_minutes = 60, max_booking_days_ahead = 30,
       min_cancel_notice_minutes = 120, min_reschedule_notice_minutes = 120,
       offer_response_minutes = 15, offer_min_lead_minutes = 60,
       public_app_url = 'https://prueba.pages.dev';
insert into working_hours (weekday, start_time, end_time)
  select d, time '09:00', time '13:00' from generate_series(0, 6) d
  union all select d, time '14:00', time '20:00' from generate_series(0, 6) d;
insert into services (id, name, price, duration_minutes, buffer_minutes) values
  ('00000000-0000-0000-0000-000000000060', 'Servicio 60', 1000, 60, 0),
  ('00000000-0000-0000-0000-000000000030', 'Servicio 30',  500, 30, 0),
  ('00000000-0000-0000-0000-000000000061', 'Servicio 60 + 15 extra', 1200, 60, 15),
  ('00000000-0000-0000-0000-000000000090', 'Servicio 90', 1500, 90, 0);
\set S60 '''00000000-0000-0000-0000-000000000060'''
\set S30 '''00000000-0000-0000-0000-000000000030'''
\set S6015 '''00000000-0000-0000-0000-000000000061'''
\set S90 '''00000000-0000-0000-0000-000000000090'''

\echo '--- 1. Seguridad'
:ANON
select t_err('select * from agenda', 'permission denied', 'anon no lee la agenda');
select t_err('select * from customers', 'permission denied', 'anon no lee clientes');
select t_err('select admin_estadisticas(current_date, current_date)', 'permission denied', 'anon no usa funciones del panel');
select t_err('select _offer_next(null)', 'permission denied', 'anon no usa funciones internas');
select t_err('select _procesar_vencimientos()', 'permission denied', 'anon no dispara tareas internas');

\echo '--- 2. Disponibilidad'
select t_ok((select count(*) from horarios_disponibles(:S60, (t_at('00:00', 2) at time zone 'America/Argentina/Buenos_Aires')::date)) = 7 + 11,
            '18 horarios de 60 min (9–13 y 14–20, cada 30 min)');
select t_ok(not exists (select 1 from horarios_disponibles(:S60, (t_at('00:00', 2) at time zone 'America/Argentina/Buenos_Aires')::date) h
                        where h = t_at('12:30', 2)), 'un servicio de 60 min no puede empezar 12:30 (choca con el descanso)');
select t_ok((select count(*) from horarios_disponibles(:S60, (t_at('00:00', 40) at time zone 'America/Argentina/Buenos_Aires')::date)) = 0,
            'no se reserva más allá de 30 días');

\echo '--- 3. Reservas del ejemplo (día +2)'
select reservar(:S60, t_at('10:00', 2), 'Lucas',   '5491100000001', null, null, false, true) ->> 'token' as tok_lucas \gset
select reservar(:S60, t_at('11:00', 2), 'Martín',  '5491100000002', null, null, false, true) ->> 'token' as tok_martin \gset
select reservar(:S60, t_at('12:00', 2), 'Facundo', '5491100000003', null, null, true,  true) ->> 'token' as tok_facundo \gset
select reservar(:S60, t_at('14:00', 2), 'Juan',    '5491100000004', null, null, true,  true) ->> 'token' as tok_juan \gset
select reservar(:S60, t_at('15:00', 2), 'Nicolás', '5491100000005', null, null, true,  true) ->> 'token' as tok_nico \gset
select t_ok((select count(*) from mis_turnos(array[:'tok_facundo'])) = 1, 'Facundo ve su turno con su enlace');
select t_ok((select count(*) from mis_turnos(array['enlace-falso'])) = 0, 'un enlace falso no muestra nada');
select t_err(format('select reservar(%L, %L, ''Otro'', ''5491100000099'', null, null, false, true)', :S60, t_at('10:00', 2)),
             'HORARIO_NO_DISPONIBLE', 'no se puede reservar un horario ocupado');
select t_err(format('select reservar(%L, %L, ''Otro'', ''5491100000099'', null, null, false, true)', :S60, t_at('10:30', 2)),
             'HORARIO_NO_DISPONIBLE', 'no se puede reservar un horario que se superpone');
select t_err(format('select reservar(%L, %L, ''Otro'', ''5491100000099'', null, null, false, false)', :S60, t_at('16:00', 2)),
             'FALTA_CONSENTIMIENTO', 'hace falta aceptar el aviso de privacidad');
select t_err(format('select reservar(%L, %L, ''Otro'', ''123'', null, null, false, true)', :S60, t_at('16:00', 2)),
             'TELEFONO_INVALIDO', 'teléfono inválido');

\echo '--- 4. Facundo y Juan activan notificaciones; Nicolás no'
select registrar_push(:'tok_facundo', 'https://push.example/facundo', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select registrar_push(:'tok_juan', 'https://push.example/juan', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select t_err(format('select preferencia_adelanto(%L, true)', :'tok_lucas'), 'NECESITA_NOTIFICACIONES',
             'sin notificaciones no se puede activar "avisarme si se libera antes"');

\echo '--- 5. Martín cancela → la oferta de las 11:00 le llega sola a Facundo'
select cancelar_turno(:'tok_martin') is not null as x \gset
:ROOT
select t_ok((select count(*) from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
             where c.name = 'Facundo' and o.status = 'sent' and lower(o.proposed_period) = t_at('11:00', 2)) = 1,
            'oferta para Facundo a las 11:00, enviada sin aprobación');
select t_ok((select count(*) from agenda where kind = 'hold' and status = 'active' and lower(period) = t_at('11:00', 2)) = 1,
            'el hueco de las 11:00 queda retenido');
:ANON
select t_ok(not exists (select 1 from horarios_disponibles(:S30, (t_at('00:00', 2) at time zone 'America/Argentina/Buenos_Aires')::date) h
                        where h = t_at('11:00', 2)), 'nadie más puede reservar las 11:00 mientras se ofrece');

\echo '--- 6. Facundo acepta desde la notificación → cascada a Juan'
:ROOT
select split_part(q.url, '#', 2) as tok_of_facundo from notification_queue q join customers c on c.id = q.customer_id
 where c.name = 'Facundo' and q.kind = 'advance' \gset
:ANON
select t_ok((ver_oferta(:'tok_of_facundo') ->> 'estado') = 'sent', 'Facundo ve la oferta');
select t_ok((responder_oferta(:'tok_of_facundo', true) ->> 'result') = 'aceptada', 'Facundo acepta');
select t_ok((select inicio from mis_turnos(array[:'tok_facundo'])) = t_at('11:00', 2), 'el turno de Facundo pasó a las 11:00');
:ROOT
select t_ok((select count(*) from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
             where c.name = 'Juan' and o.status = 'sent' and lower(o.proposed_period) = t_at('12:00', 2)) = 1,
            'cascada: las 12:00 se ofrecen a Juan y salen solas (tiene push)');
select t_ok((select count(*) from notification_queue q join customers c on c.id = q.customer_id
             where c.name = 'Juan' and q.kind = 'advance' and q.url like '/oferta#%') = 1,
            'se encoló el aviso push para Juan');

\echo '--- 7. Juan rechaza desde Mis turnos → pasa a Nicolás; vence → el hueco vuelve al público'
:ANON
select registrar_push(:'tok_nico', 'https://push.example/nico', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select t_ok((select oferta ->> 'tipo' from mis_turnos(array[:'tok_juan'])) = 'advance', 'Juan ve la oferta en Mis turnos');
select t_ok((responder_oferta_de_mi_turno(:'tok_juan', false) ->> 'result') = 'rechazada', 'Juan rechaza');
select t_ok((select inicio from mis_turnos(array[:'tok_juan'])) = t_at('14:00', 2), 'Juan conserva su turno de las 14:00');
:ROOT
select t_ok((select count(*) from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
             where c.name = 'Nicolás' and o.status = 'sent') = 1, 'ahora se le ofrece a Nicolás');
update offers set expires_at = now() - interval '1 second' where status = 'sent';
select t_ok(_procesar_vencimientos() = 1, 'la tarea programada vence la oferta de Nicolás');
select t_ok((select status from freed_slots order by created_at desc limit 1) = 'exhausted', 'sin más candidatos, el hueco se cierra');
:ANON
select t_ok(exists (select 1 from horarios_disponibles(:S60, (t_at('00:00', 2) at time zone 'America/Argentina/Buenos_Aires')::date) h
                    where h = t_at('12:00', 2)), 'las 12:00 vuelven a estar disponibles al público');

\echo '--- 8. Propuesta del peluquero: el turno original sigue hasta que el cliente acepte'
:ADMIN
select admin_proponer_horario((select a.id from agenda a join customers c on c.id = a.customer_id where c.name = 'Lucas'),
                              t_at('16:00', 2)) ->> 'token_oferta' as tok_prop \gset
:ANON
select t_ok((select inicio from mis_turnos(array[:'tok_lucas'])) = t_at('10:00', 2), 'mientras decide, Lucas sigue a las 10:00');
select t_ok(not exists (select 1 from horarios_disponibles(:S60, (t_at('00:00', 2) at time zone 'America/Argentina/Buenos_Aires')::date) h
                        where h = t_at('16:00', 2)), 'las 16:00 quedan retenidas para Lucas');
select t_ok((responder_oferta(:'tok_prop', true) ->> 'result') = 'aceptada', 'Lucas acepta la propuesta');
select t_ok((select inicio from mis_turnos(array[:'tok_lucas'])) = t_at('16:00', 2), 'Lucas pasó a las 16:00');
select t_ok((responder_oferta(:'tok_prop', true) ->> 'result') = 'no_disponible', 'una oferta no se puede usar dos veces');

\echo '--- 9. Cliente reprograma su turno'
select t_ok((reprogramar_turno(:'tok_nico', t_at('17:00', 2)) ->> 'inicio')::timestamptz = t_at('17:00', 2), 'Nicolás pasa de 15:00 a 17:00');
:ROOT
select t_ok(not exists (select 1 from offers o join agenda a on a.id = o.appointment_id join customers c on c.id = a.customer_id
                        where c.name = 'Nicolás' and o.status in ('pending_approval', 'sent')),
            'a Nicolás no se le ofrece el horario que acaba de dejar');
:ANON
select t_err(format('select reprogramar_turno(%L, %L)', :'tok_nico', t_at('16:00', 2)), 'HORARIO_NO_DISPONIBLE',
             'no puede moverse a un horario ocupado');

\echo '--- 10. Bloqueos'
:ADMIN
select t_err(format('select admin_bloquear(%L, %L, ''Imprevisto'')', t_at('13:30', 2), t_at('15:00', 2)),
             'HAY_TURNOS_EN_CONFLICTO', 'bloquear sobre turnos avisa del conflicto');
select t_ok(jsonb_array_length(admin_bloquear_resto_jornada(t_at('13:30', 2), 'Imprevisto', true) -> 'turnos_cancelados') = 3,
            'bloquear el resto de la jornada cancela a Juan, Lucas y Nicolás y los devuelve para avisarles');
:ANON
select t_ok((select count(*) from horarios_disponibles(:S30, (t_at('00:00', 2) at time zone 'America/Argentina/Buenos_Aires')::date) h
             where h >= t_at('13:30', 2)) = 0, 'después del bloqueo no hay horarios esa tarde');
:ADMIN
select t_ok((admin_bloquear_dias((t_at('00:00', 5) at time zone 'America/Argentina/Buenos_Aires')::date,
                                 (t_at('00:00', 7) at time zone 'America/Argentina/Buenos_Aires')::date, 'Vacaciones') ->> 'bloqueo_id') is not null,
            'vacaciones de 3 días');
:ANON
select t_ok((select sum(horarios) from dias_disponibles(:S60, (t_at('00:00', 5) at time zone 'America/Argentina/Buenos_Aires')::date,
                                                        (t_at('00:00', 7) at time zone 'America/Argentina/Buenos_Aires')::date)) = 0,
            'en vacaciones no hay horarios');

\echo '--- 11. Tiempo extra entre turnos'
select reservar(:S6015, t_at('16:00', 3), 'Ana', '5491100000006', null, null, false, true) ->> 'token' as tok_ana \gset
select t_ok(not exists (select 1 from horarios_disponibles(:S30, (t_at('00:00', 3) at time zone 'America/Argentina/Buenos_Aires')::date) h
                        where h = t_at('17:00', 3)), 'las 17:00 no están libres (tiempo extra hasta 17:15)');
select t_ok(exists (select 1 from horarios_disponibles(:S30, (t_at('00:00', 3) at time zone 'America/Argentina/Buenos_Aires')::date) h
                    where h = t_at('17:30', 3)), 'las 17:30 sí');

\echo '--- 12. Plazos de cancelación y estados'
:ADMIN
select admin_crear_turno('Pedro', '5491100000007', :S30, date_trunc('minute', now()) + interval '90 minutes', null, true) ->> 'token' as tok_pedro \gset
:ANON
select t_err(format('select cancelar_turno(%L)', :'tok_pedro'), 'FUERA_DE_PLAZO_CANCELACION', 'no se cancela con menos de 2 h');
:ADMIN
select t_err(format('select admin_marcar_turno(%L, ''completed'')',
                    (select id from agenda a where a.manage_token_hash is not null and a.service_name = 'Servicio 30' limit 1)),
             'TURNO_AUN_NO_EMPEZO', 'no se marca realizado un turno que no empezó');
select t_err(format('select admin_crear_turno(''Xavier'', ''5491100000008'', %L, %L)', :S30, t_at('11:00', 2)),
             'HORARIO_OCUPADO', 'el peluquero tampoco puede superponer turnos');

\echo '--- 13. RLS con usuario logueado que no es el administrador'
:ROOT
:OTRO
select t_ok((select count(*) from agenda) = 0, 'otro usuario no ve ningún turno');
select t_err('select admin_estadisticas(current_date, current_date + 30)', 'NO_AUTORIZADO', 'otro usuario no ve estadísticas');
update settings set booking_enabled = false;
:ROOT
select t_ok((select booking_enabled from settings), 'el update de un no-admin no cambió nada');
:ADMIN
select t_ok((select count(*) from agenda) > 0, 'el administrador ve la agenda');
select t_err('update settings set owner_user_id = null', 'permission denied', 'ni el admin puede cambiar el dueño por la API');
select t_ok((admin_estadisticas((now() at time zone 'America/Argentina/Buenos_Aires')::date,
                                (now() at time zone 'America/Argentina/Buenos_Aires')::date + 30) ->> 'total')::int >= 6,
            'estadísticas del período');

\echo '--- 14. Adelanto con servicio más largo que el hueco (y modo con aprobación, opcional)'
:ROOT
update settings set offers_mode = 'approval';
:ANON
select reservar(:S30, t_at('10:30', 4), 'Bruno', '5491100000010', null, null, false, true) ->> 'token' as tok_bruno \gset
select reservar(:S90, t_at('11:00', 4), 'Carla', '5491100000011', null, null, true, true) ->> 'token' as tok_carla \gset
select registrar_push(:'tok_carla', 'https://push.example/carla', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select cancelar_turno(:'tok_bruno') is not null as x \gset
:ROOT
select t_ok((select upper(period) from agenda where kind = 'hold' and status = 'active' and lower(period) = t_at('10:30', 4)) = t_at('11:00', 4),
            'hueco de 30 min: se retiene sólo 10:30–11:00 (el resto es el turno de Carla)');
:ADMIN
select admin_aprobar_oferta((select id from offers where status = 'pending_approval')) ->> 'token_oferta' as tok_of_carla \gset
:ANON
select t_ok((responder_oferta(:'tok_of_carla', true) ->> 'result') = 'aceptada', 'Carla (90 min) adelanta a las 10:30');
select t_ok((select fin from mis_turnos(array[:'tok_carla'])) = t_at('12:00', 4), 'Carla queda 10:30–12:00');
select t_ok(exists (select 1 from horarios_disponibles(:S30, (t_at('00:00', 4) at time zone 'America/Argentina/Buenos_Aires')::date) h
                    where h = t_at('12:00', 4)), 'las 12:00 quedan libres para otra persona');
:ROOT
update settings set offers_mode = 'auto';

\echo '--- 15. Avisos al peluquero'
:ADMIN
select admin_registrar_push('https://push.example/admin', repeat('k', 40), repeat('a', 16)) is not null as x \gset
:ANON
select reservar(:S30, t_at('10:00', 3), 'Diego', '5491100000012', null, null, false, true) ->> 'token' as tok_diego \gset
select reservar(:S30, t_at('11:00', 3), 'Eva',   '5491100000013', null, null, false, true) ->> 'token' as tok_eva \gset
select registrar_push(:'tok_eva', 'https://push.example/eva', repeat('k', 40), repeat('a', 16)) is not null as x \gset
select reprogramar_turno(:'tok_diego', t_at('09:30', 3)) is not null as x \gset
:ROOT
select t_ok((select count(*) from notification_queue where to_admin and title = 'Nueva reserva' and body like 'Diego · Servicio 30 · %') = 1,
            'al peluquero le llega "Nueva reserva: Diego"');
select t_ok((select count(*) from notification_queue where to_admin and title = 'Turno cambiado' and body like 'Diego pasó del %') = 1,
            'y "Turno cambiado" cuando Diego se mueve solo, sin aprobación');

\echo '--- 16. Panel de cancelación: vista previa, mensajes personales y opción "elegir otro horario"'
:ADMIN
select t_ok((select count(*) from message_templates) = 5, 'hay 5 mensajes listos para elegir');
select t_ok(jsonb_array_length(admin_cancelar_y_avisar(t_at('09:00', 3), t_at('13:00', 3), 'elegir_otro',
              (select id from message_templates where title = 'Imprevisto')) -> 'afectados') = 2,
            'la vista previa muestra a Diego y Eva');
select t_ok((select count(*) from agenda where status = 'confirmed' and lower(period) between t_at('09:00', 3) and t_at('12:00', 3)) = 2,
            'la vista previa no cambia nada');
select admin_cancelar_y_avisar(t_at('09:00', 3), t_at('13:00', 3), 'elegir_otro',
         (select id from message_templates where title = 'Imprevisto'), null, 'Imprevisto', true) as res \gset
select t_ok((:'res'::jsonb -> 'afectados' -> 0 ->> 'mensaje') like 'Hola Diego, ¿cómo estás? Te escribo porque por un imprevisto no voy a poder atenderte el % a las 09:30.%Elegí otro horario acá: https://prueba.pages.dev/turno#%',
            'mensaje personal para Diego con su día, hora y enlace');
select t_ok((:'res'::jsonb -> 'afectados' -> 0 ->> 'whatsapp_url') like 'https://wa.me/5491100000012?text=Hola%20Diego%',
            'botón de WhatsApp con el mensaje ya escrito');
select t_ok((:'res'::jsonb -> 'afectados' -> 1 ->> 'tiene_push')::boolean, 'a Eva además le llega por notificación');
select substring(:'res'::jsonb -> 'afectados' -> 0 ->> 'mensaje' from '/turno#([0-9a-f]{64})') as tok_diego2 \gset
:ANON
select t_ok((select count(*) from mis_turnos(array[:'tok_diego'])) = 0, 'el enlace viejo de Diego deja de valer');
select t_ok((select debe_elegir_horario from mis_turnos(array[:'tok_diego2'])), 'con el enlace nuevo Diego ve que tiene que elegir horario');
select t_ok((reprogramar_turno(:'tok_diego2', t_at('14:00', 3)) ->> 'inicio')::timestamptz = t_at('14:00', 3),
            'Diego elige las 14:00 y queda confirmado');
select t_ok((select estado from mis_turnos(array[:'tok_diego2'])) = 'confirmed', 'su turno vuelve a estar activo');

\echo '--- 17. Opción "sólo avisar": el cliente no puede reubicar ese turno'
:ADMIN
select admin_cancelar_y_avisar(t_at('09:00', 4), t_at('13:00', 4), 'solo_avisar', null,
         'Hola {nombre}, hoy no abro. Tu turno del {dia} a las {hora} queda cancelado. {enlace}', 'Cierre', true)
       -> 'afectados' -> 0 ->> 'mensaje' as msg_carla \gset
select t_ok(:'msg_carla' like 'Hola Carla, hoy no abro.%Cuando quieras, reservá de nuevo acá: https://prueba.pages.dev',
            'mensaje propio escrito por el peluquero');
:ANON
select t_ok((select estado from mis_turnos(array[:'tok_carla'])) = 'cancelled_by_admin', 'Carla ve su turno como cancelado con su mismo enlace');
select t_err(format('select reprogramar_turno(%L, %L)', :'tok_carla', t_at('15:00', 4)), 'TURNO_NO_MODIFICABLE',
             'Carla no puede reubicar ese turno');

\echo '--- 18. Reservas hasta 5 días'
:ROOT
update settings set max_booking_days_ahead = 5;
:ANON
select t_ok((select count(*) from horarios_disponibles(:S30, (t_at('00:00', 6) at time zone 'America/Argentina/Buenos_Aires')::date)) = 0
         and (select count(*) from horarios_disponibles(:S30, (t_at('00:00', 4) at time zone 'America/Argentina/Buenos_Aires')::date)) > 0,
            'con 5 días: el día +4 tiene horarios y el +6 no');
:ROOT
update settings set max_booking_days_ahead = 30;

:ROOT
\echo '--- Todas las pruebas de flujos pasaron'
