#!/usr/bin/env bash
# Crea una base limpia, aplica las migraciones 01–06 y corre las pruebas.
# Uso: PGHOST=/tmp PGPORT=5544 PGUSER=postgres ./tests/correr_pruebas.sh
set -euo pipefail
cd "$(dirname "$0")/.."
DB=${DB:-turnos_test}
P="psql -v ON_ERROR_STOP=1 -q"
$P -d postgres -c "drop database if exists $DB" -c "create database $DB"
$P -d "$DB" -f tests/00_simular_supabase.sql
for f in migrations/*.sql; do
  case "$f" in *tareas_programadas*) continue ;; esac   # pg_cron sólo existe en Supabase
  $P -d "$DB" -f "$f"
done
$P -d "$DB" -f tests/10_pruebas_flujos.sql

echo '--- 19. Concurrencia: 30 reservas simultáneas del mismo horario'
pgbench -n -c 30 -j 30 -t 1 -f tests/20_concurrencia.pgbench "$DB" >/tmp/pgbench.log 2>&1 || true
N=$(psql -tA -d "$DB" -c "select count(*) from agenda where kind='appointment' and lower(period) = t_at('10:00', 8) and status <> 'cancelled_by_customer'")
if [ "$N" = "1" ]; then echo "OK  exactamente 1 de 30 reservas simultáneas quedó registrada"; else echo "FALLO: quedaron $N"; cat /tmp/pgbench.log; exit 1; fi
