# Turnos para peluquerías

Plataforma de turnos online para peluqueros independientes. Cada peluquero se registra, la plataforma lo activa por mes pago, y obtiene su propia app de reservas en `tuapp/<su-nombre>` (con un QR para sus clientes) y su panel privado. Los clientes reservan sin crear cuenta, cambian su horario solos y pueden pedir que les avisen si se libera un turno antes. El peluquero recibe un aviso por cada reserva y tiene un panel para bloquear horarios y avisar a cada cliente con un mensaje personal.

Stack: React + Vite (próxima etapa), Supabase (PostgreSQL, Auth, Realtime, RLS, Cron) y Cloudflare Pages.

## Demo

[`demo/index.html`](demo/index.html) es una demo navegable de las pantallas de una peluquería (app del cliente y panel del peluquero), con datos de ejemplo. Es un solo archivo: se abre en el navegador sin instalar nada.

## Cómo funciona la plataforma

| Quién | Qué hace |
| --- | --- |
| Dueño de la plataforma | Ve todas las peluquerías, activa cada una hasta una fecha (mes pago) y las suspende. `super_peluquerias`, `super_activar`, `super_suspender`, `super_configurar` |
| Peluquero | Crea su cuenta, registra su peluquería (`registrar_peluqueria`) y queda **pendiente**. Ya activo, carga servicios y horarios, abre las reservas y usa su panel |
| Cliente | Entra por el QR o el enlace `tuapp/<slug>`, reserva, ve y cambia sus turnos |

- **Estado de cada peluquería:** `pending` (registrada, sin aprobar, no es pública) · `active` · `suspended`. Además, si `paid_until` ya pasó, deja de tomar reservas sola, sin que nadie haga nada. Sus clientes siguen viendo y cancelando sus turnos.
- **Renovar:** `super_activar(id)` extiende un mes desde el vencimiento (o desde hoy si ya venció) y registra el pago en `subscription_payments`.
- **Aislamiento:** todas las tablas tienen `shop_id` y RLS. Cada peluquero ve y modifica sólo lo suyo; el mismo teléfono en dos peluquerías son dos clientes distintos; las agendas no se cruzan. Está probado.

## Estructura

```
supabase/
  migrations/
    20261121000100_esquema.sql            peluquerías, tablas, restricción anti-superposición por peluquería
    20261121000200_nucleo.sql             funciones internas (disponibilidad, identidad, avisos)
    20261121000300_lista_espera.sql       horarios liberados, ofertas, cascada, vencimientos
    20261121000400_funciones_cliente.sql  app de clientes (por dirección de peluquería)
    20261121000500_funciones_admin.sql    registro y panel del peluquero
    20261121000550_plataforma.sql         panel del dueño de la plataforma
    20261121000600_seguridad.sql          RLS y permisos
    20261121000700_tareas_programadas.sql pg_cron (sólo en Supabase)
  tests/
    correr_pruebas.sh                     corre todo en un PostgreSQL local
.github/workflows/
  mantener-activo.yml                     evita la pausa del plan gratuito
  respaldo-semanal.yml                    volcado semanal cifrado
demo/index.html                           demo navegable
```

## Instalación en Supabase

1. **Extensiones:** habilitar `pg_cron` (Integrations → Cron) y `btree_gist` (Database → Extensions).
2. **Migraciones**, en orden:
   ```bash
   supabase init
   supabase link --project-ref <ref-del-proyecto>
   supabase db push
   ```
3. **Registro de peluqueros:** dejar habilitado "Allow new users to sign up". Como el correo incluido en Supabase sólo sirve para pruebas, hay dos opciones: desactivar "Confirm email" (las cuentas igual quedan pendientes hasta que las actives) o configurar un SMTP propio.
4. **Tu usuario de dueño:** creá tu cuenta y en el SQL Editor:
   ```sql
   insert into public.platform_admins (user_id) values ('<tu id de usuario>');
   ```
5. **Dirección de la app:** `select super_configurar('https://tu-app.pages.dev');` logueado como dueño, o `update platform_settings set app_url = '…'` en el SQL Editor.
6. **Secrets de GitHub** (Settings → Secrets → Actions): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_DB_URL` (Session pooler), `BACKUP_PASSPHRASE`.

## Reglas de agenda (por peluquería)

- **Cero superposiciones:** turnos, bloqueos y retenciones viven en `agenda`; la restricción `agenda_no_overlap` (peluquería + rango) rechaza dos filas activas que se pisen, incluido el tiempo extra entre turnos. Probado con 30 reservas simultáneas: entra 1.
- **Clientes sin cuenta:** cada reserva devuelve un enlace privado (`token`); en la base sólo queda su huella SHA-256.
- **Sin aprobaciones:** las reservas se confirman solas, el cliente cambia su horario solo (hasta 5 días hacia adelante, configurable) y el peluquero recibe un push por cada reserva, cambio o cancelación.
- **Lista de espera automática:** al liberarse un horario se ofrece al turno más cercano del mismo día que pidió aviso y tiene notificaciones; el hueco queda retenido; aceptar mueve el turno y ofrece el horario que dejó (cascada); rechazar o vencer pasa al siguiente.
- **Panel de cancelación** (`admin_cancelar_y_avisar`): rango + opción (`elegir_otro` o `solo_avisar`) + plantilla o texto propio. Vista previa sin cambios; al confirmar bloquea, cancela, manda push y devuelve un mensaje personal y un botón `wa.me` por cliente.

## Funciones

**App de clientes (sin login):** `info_negocio(slug)`, `servicios_publicos(slug)`, `dias_disponibles(slug, …)`, `horarios_disponibles(slug, …)`, `reservar(slug, …)`, `mis_turnos`, `cancelar_turno`, `horarios_para_mi_turno`, `reprogramar_turno`, `preferencia_adelanto`, `ver_oferta`, `responder_oferta`, `responder_oferta_de_mi_turno`, `elegir_otro_horario`, `registrar_push`.

**Peluquero (logueado):** `registrar_peluqueria`, `mi_peluqueria`, `admin_crear_turno`, `admin_cancelar_turno`, `admin_reprogramar_turno`, `admin_proponer_horario`, `admin_marcar_turno`, `admin_enlace_turno`, `admin_bloquear`, `admin_bloquear_resto_jornada`, `admin_bloquear_dias`, `admin_quitar_bloqueo`, `admin_cancelar_y_avisar`, `admin_ofrecer_hueco`, `admin_aprobar_oferta`, `admin_descartar_oferta`, `admin_enlace_oferta`, `admin_registrar_push`, `admin_estadisticas`. Configuración, servicios, horarios, plantillas, clientes y cobros se editan directo en sus tablas (RLS; `shop_id` se completa solo).

**Dueño de la plataforma:** `super_peluquerias`, `super_activar`, `super_suspender`, `super_configurar`.

## Códigos de error

| Código | Qué mostrar |
| --- | --- |
| `PELUQUERIA_INEXISTENTE` | Esa peluquería no existe |
| `HORARIO_NO_DISPONIBLE` | Ese horario ya no está disponible, elegí otro |
| `RESERVAS_DESHABILITADAS` | Esta peluquería no está tomando reservas online por el momento |
| `FALTA_CONSENTIMIENTO` | Hay que aceptar el aviso de privacidad |
| `NOMBRE_INVALIDO` · `TELEFONO_INVALIDO` · `EMAIL_INVALIDO` · `NOTA_DEMASIADO_LARGA` | Revisá el dato |
| `SERVICIO_NO_DISPONIBLE` | El servicio no está disponible |
| `BLOQUEADO_POR_AUSENCIAS` | Escribinos por WhatsApp para reservar |
| `LIMITE_DE_TURNOS` | Ya tenés el máximo de turnos reservados |
| `ENLACE_INVALIDO` | El enlace no es válido |
| `TURNO_NO_MODIFICABLE` | Ese turno ya no se puede modificar |
| `FUERA_DE_PLAZO_CANCELACION` · `FUERA_DE_PLAZO_REPROGRAMACION` | Fuera de plazo: escribinos por WhatsApp |
| `NECESITA_NOTIFICACIONES` | Para recibir avisos de adelanto, activá las notificaciones |
| `OFERTA_NO_DISPONIBLE` · `OFERTA_VENCIDA` | La oferta ya no está disponible |
| `YA_TENES_PELUQUERIA` · `DIRECCION_INVALIDA` · `DIRECCION_EN_USO` · `DIRECCION_RESERVADA` | (registro) Elegí otra dirección |
| `HORARIO_OCUPADO` · `FUERA_DE_HORARIO` · `HORARIO_MUY_CERCANO` · `HAY_TURNOS_EN_CONFLICTO` · `RANGO_INVALIDO` · `RANGO_SUPERPUESTO` · `OPCION_INVALIDA` · `PLANTILLA_INVALIDA` · `FALTA_DIRECCION_APP` · `ESTADO_INVALIDO` · `TURNO_AUN_NO_EMPEZO` · `TURNO_INEXISTENTE` | (panel) |
| `NO_AUTORIZADO` · `FECHA_INVALIDA` | (panel / plataforma) |

## Pruebas

Requiere PostgreSQL 15+ local con `btree_gist`:

```bash
PGHOST=localhost PGUSER=postgres ./supabase/tests/correr_pruebas.sh
```

103 comprobaciones: registro, aprobación, vencimiento y suspensión; aislamiento entre dos peluquerías (lectura, escritura y funciones); seguridad de anon; disponibilidad; todo el ejemplo de lista de espera con cascada, rechazo y vencimiento; propuestas; reprogramación; bloqueos y vacaciones; tiempo extra; plazos; avisos al peluquero; panel de cancelación; límite de 5 días; y 30 reservas simultáneas.

## Límites del plan gratuito con varias peluquerías

Para decenas de peluquerías alcanza: 500 MB de base, 50.000 usuarios activos por mes y 200 conexiones de Realtime simultáneas. Lo primero que se va a quedar corto al crecer son las conexiones de Realtime (por eso los clientes sólo se conectan mientras miran la pantalla de horarios). Revisar los límites vigentes antes de lanzar.

## Pendiente

- App React + Vite: app del cliente por `/<slug>`, panel del peluquero, registro, panel de la plataforma, generación del QR, PWA.
- Edge Function que vacía `notification_queue` y envía los push (VAPID).
- Protección contra registros y reservas falsas (por ejemplo Cloudflare Turnstile): a confirmar.
- Términos de uso para peluqueros y aviso de privacidad para sus clientes (Ley 25.326): cada peluquero es responsable de sus datos y la plataforma los trata por cuenta de él.
- Repositorio público: antes de usar datos reales, pasar `respaldo-semanal.yml` a un repo privado o desactivarlo.
