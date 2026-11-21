-- =====================================================================
-- 07 · Tareas programadas (Supabase Cron / pg_cron)
-- Requiere la extensión pg_cron: en el panel de Supabase,
-- Integrations → Cron → Enable (o Database → Extensions → pg_cron).
-- =====================================================================

create extension if not exists pg_cron;

-- Cada minuto: vencer ofertas, pasar al siguiente candidato, liberar retenciones.
select cron.schedule(
  'turnos-procesar-vencimientos',
  '* * * * *',
  $$select public._procesar_vencimientos()$$
);

-- Limpieza semanal: avisos ya enviados con más de 7 días.
select cron.schedule(
  'turnos-limpiar-avisos',
  '17 4 * * 1',
  $$delete from public.notification_queue where sent_at < now() - interval '7 days'$$
);
