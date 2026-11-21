# Turnos para peluquería

App web para que un peluquero independiente reciba reservas online y administre su agenda: reservas sin cuenta, cambios de horario por el propio cliente, lista de espera automática que ofrece los turnos liberados, panel de cancelación con mensajes personalizados por WhatsApp, y avisos push. Stack: React + Vite (próxima etapa), Supabase (PostgreSQL, Auth, Realtime, RLS) y Cloudflare Pages.

## Demo

[`demo/index.html`](demo/index.html) es una demo navegable de las pantallas (app del cliente y panel del peluquero), con datos de ejemplo. Es un solo archivo: se abre en el navegador sin instalar nada. Para publicarla, en Settings → Pages elegí la rama `main` y la carpeta `/ (root)`; queda en `https://<usuario>.github.io/turnos-peluqueria/demo/`.

> **Repositorio público:** antes de usar la versión real, pasá el workflow `respaldo-semanal.yml` a un repositorio privado o desactivalo. Los respaldos van cifrados, pero no conviene dejarlos en un repo público.

## Etapa 1: base de datos

Esta entrega es la base de datos completa en Supabase: tablas, la regla que impide reservas duplicadas, funciones para clientes y para el panel, lista de espera, seguridad (RLS) y tareas programadas. La app en React (pantallas) es la próxima entrega.

**No hay datos del negocio cargados.** La reserva online arranca **deshabilitada** (`booking_enabled = false`) hasta que se carguen servicios, horarios y políticas reales.

## Qué hay

```
supabase/
  migrations/
    20261121000100_esquema.sql            tablas + restricción anti-superposición
    20261121000200_nucleo.sql             funciones internas (disponibilidad, permisos)
    20261121000300_lista_espera.sql       horarios liberados, ofertas, cascada, vencimientos
    20261121000400_funciones_cliente.sql  lo que usa la app de clientes
    20261121000500_funciones_admin.sql    lo que usa el panel del peluquero
    20261121000600_seguridad.sql          RLS y permisos
    20261121000700_tareas_programadas.sql pg_cron (sólo en Supabase)
    20261121000800_ajustes_peluquero.sql  5 días, avisos al peluquero, panel de cancelación
  tests/
    correr_pruebas.sh                     corre todo en un PostgreSQL local
.github/workflows/
  mantener-activo.yml                     evita la pausa del plan gratuito
  respaldo-semanal.yml                    volcado semanal cifrado
```

## Instalación en Supabase

1. **Habilitar pg_cron:** Integrations → Cron → Enable (o Database → Extensions → `pg_cron`).
2. **Aplicar las migraciones**, en orden, con la CLI:
   ```bash
   supabase init            # crea supabase/config.toml; respeta la carpeta migrations
   supabase link --project-ref <ref-del-proyecto>
   supabase db push
   ```
   Alternativa sin CLI: pegar cada archivo, en orden, en el SQL Editor.
3. **Crear el usuario del peluquero:** Authentication → Users → Add user (email + contraseña).
4. **Nombrarlo administrador** (SQL Editor):
   ```sql
   update public.settings set owner_user_id = '<id del usuario>';
   ```
5. **Cerrar el registro público:** Authentication → Sign In / Providers → desactivar "Allow new users to sign up". Sin esto cualquiera podría crear una cuenta (igual no vería nada, pero no hace falta).
6. **Secrets de GitHub** (Settings → Secrets → Actions): `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_DB_URL` (Session pooler), `BACKUP_PASSPHRASE`.
7. Cargar en `settings.public_app_url` la dirección de la app (p. ej. `https://mi-peluqueria.pages.dev`); la usan los enlaces de WhatsApp.
8. Cuando lleguen los datos del peluquero: cargar `services`, `working_hours`, completar `settings` y poner `booking_enabled = true`.

## Cómo funciona

- **Cero superposiciones.** Turnos, bloqueos y retenciones están en `agenda`. La restricción `agenda_no_overlap` rechaza dos filas activas que se pisen, incluido el tiempo extra entre turnos. Probado con 30 reservas simultáneas del mismo horario: entra 1.
- **Clientes sin cuenta.** Cada reserva devuelve un `token` (enlace privado). El celular lo guarda y lo usa para ver, cancelar o mover su turno. En la base sólo queda su huella SHA-256. Si el cliente pierde el enlace, el panel genera uno nuevo (`admin_enlace_turno`).
- **Sin aprobaciones.** Las reservas se confirman solas y el cliente cambia su horario solo, hasta 5 días hacia adelante (`max_booking_days_ahead = 5`). Al peluquero le llega un aviso push por cada reserva, cambio o cancelación de un cliente (`admin_registrar_push` registra su celular).
- **Lista de espera** (decisiones acordadas):
  - Se activa cuando un cliente cancela o mueve su turno, o cuando un cliente adelanta (cascada, mismo día). Si cancela el peluquero, sólo se activa si él lo pide (`p_ofrecer_hueco` o `admin_ofrecer_hueco`).
  - Se ofrece al turno más cercano del mismo día que activó "avisarme si se libera antes", si su servicio entra en el hueco (contando su propio turno si es contiguo) y dentro del horario de atención.
  - El hueco queda **retenido** mientras se espera la respuesta.
  - Sólo se ofrece si, con el tiempo de respuesta, sigue quedando el margen mínimo para llegar (`offer_min_lead_minutes`).
  - Es 100 % automática (`offers_mode = 'auto'`): la oferta llega por notificación y nadie aprueba nada. Sólo participan clientes con notificaciones activadas; sin ellas, "avisarme si se libera antes" no se puede activar (`NECESITA_NOTIFICACIONES`). El modo `approval` queda disponible por si algún día se quiere revisar cada oferta.
- **Panel de cancelación** (`admin_cancelar_y_avisar`): el peluquero elige un rango (un rato, el resto del día o días enteros), qué pasa con los turnos (`elegir_otro`: el cliente recibe un enlace para elegir otro horario · `solo_avisar`: se cancela y se lo invita a reservar de nuevo) y un mensaje: una de las 5 plantillas de `message_templates` o un texto propio. Con `p_confirmar = false` devuelve la vista previa; con `true` bloquea, cancela, manda push a quien lo tenga y devuelve para cada cliente su mensaje personal y el botón `wa.me` ya armado.
- **Propuesta del peluquero** (`admin_proponer_horario`): el turno original sigue en pie y el horario propuesto queda retenido hasta que el cliente acepte, rechace o elija otro horario.
- **Tareas programadas:** cada minuto se vencen ofertas sin respuesta y se pasa al siguiente candidato.

## Funciones

**App de clientes (sin login):** `info_negocio`, `servicios_publicos`, `dias_disponibles`, `horarios_disponibles`, `reservar`, `mis_turnos`, `cancelar_turno`, `horarios_para_mi_turno`, `reprogramar_turno`, `preferencia_adelanto`, `ver_oferta`, `responder_oferta`, `responder_oferta_de_mi_turno`, `elegir_otro_horario`, `registrar_push`.

**Panel (sólo el administrador):** `admin_crear_turno`, `admin_cancelar_turno`, `admin_reprogramar_turno`, `admin_proponer_horario`, `admin_marcar_turno`, `admin_enlace_turno`, `admin_bloquear`, `admin_bloquear_resto_jornada`, `admin_bloquear_dias`, `admin_quitar_bloqueo`, `admin_ofrecer_hueco`, `admin_aprobar_oferta`, `admin_descartar_oferta`, `admin_enlace_oferta`, `admin_estadisticas`, `admin_cancelar_y_avisar`, `admin_registrar_push`. Servicios, plantillas de mensajes, horarios, configuración, clientes y cobros se editan directo en sus tablas (protegidas por RLS).

Las funciones que devuelven datos para WhatsApp incluyen nombre, teléfono, servicio y horario; la app arma el mensaje y el enlace `wa.me`.

## Códigos de error

| Código | Qué mostrar |
| --- | --- |
| `HORARIO_NO_DISPONIBLE` | Ese horario ya no está disponible, elegí otro |
| `RESERVAS_DESHABILITADAS` | Las reservas online no están habilitadas |
| `FALTA_CONSENTIMIENTO` | Hay que aceptar el aviso de privacidad |
| `NOMBRE_INVALIDO` · `TELEFONO_INVALIDO` · `EMAIL_INVALIDO` · `NOTA_DEMASIADO_LARGA` | Revisá el dato |
| `SERVICIO_NO_DISPONIBLE` | El servicio no está disponible |
| `BLOQUEADO_POR_AUSENCIAS` | Escribinos por WhatsApp para reservar |
| `LIMITE_DE_TURNOS` | Ya tenés el máximo de turnos reservados |
| `ENLACE_INVALIDO` | El enlace no es válido |
| `TURNO_NO_MODIFICABLE` | Ese turno ya no se puede modificar |
| `FUERA_DE_PLAZO_CANCELACION` · `FUERA_DE_PLAZO_REPROGRAMACION` | Fuera de plazo: escribinos por WhatsApp |
| `OFERTA_NO_DISPONIBLE` · `OFERTA_VENCIDA` | La oferta ya no está disponible |
| `HORARIO_OCUPADO` · `FUERA_DE_HORARIO` · `HORARIO_MUY_CERCANO` | (panel) No se puede usar ese horario |
| `NECESITA_NOTIFICACIONES` | Para recibir avisos de adelanto, activá las notificaciones |
| `OPCION_INVALIDA` · `PLANTILLA_INVALIDA` · `FALTA_DIRECCION_APP` | (panel) Revisá la opción, el mensaje o la dirección de la app en la configuración |
| `HAY_TURNOS_EN_CONFLICTO` | (panel) Hay turnos en ese rango; el detalle trae la lista. Repetir con cancelar = sí |
| `RANGO_INVALIDO` · `RANGO_SUPERPUESTO` · `ESTADO_INVALIDO` · `TURNO_AUN_NO_EMPEZO` · `NO_AUTORIZADO` | (panel) |

Respuestas de `responder_oferta`: `aceptada`, `rechazada`, `vencida`, `no_disponible`.

## Pruebas

Requiere PostgreSQL 15 o superior local (no Supabase):

```bash
PGHOST=localhost PGUSER=postgres ./supabase/tests/correr_pruebas.sh
```

Cubre: seguridad de anon y de usuarios no administradores, disponibilidad con descansos y límites de días, reservas duplicadas y superpuestas, todo el ejemplo de Lucas/Martín/Facundo/Juan/Nicolás (oferta, aprobación, aceptación, cascada, rechazo, vencimiento), propuestas del peluquero, reprogramación, bloqueos con conflicto y resto de jornada, vacaciones, tiempo extra entre turnos, plazos de cancelación, avisos al peluquero, panel de cancelación con vista previa y mensajes personales, límite de 5 días y 30 reservas simultáneas.

## Pendiente para próximas entregas

- App React + Vite (clientes y panel) y PWA.
- Edge Function que vacía `notification_queue` y envía los push (claves VAPID).
- Protección contra reservas falsas en masa (por ejemplo, Cloudflare Turnstile, gratuito): **a confirmar**, no estaba en el documento.
- Texto del aviso de privacidad (Ley 25.326).
- El respaldo copia el esquema `public`; el usuario administrador (en `auth`) se recrea a mano.

## Criterios aplicados

- El cliente cambia su horario solo, dentro del plazo de reprogramación (confirmado el 21/11/2026).
- Si cancela el peluquero, el horario no se ofrece a la lista de espera (está bloqueado).
- Un turno marcado como realizado o ausente sigue ocupando su horario.
- Si el cliente reserva con un teléfono ya registrado, se usa el cliente existente y no se cambia su nombre.
