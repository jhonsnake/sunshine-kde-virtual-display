# Iteración 2 — Orquestación connect/disconnect (KDE Plasma 6 / Wayland)

> Diseño aprobado el 2026-06-28. Contraparte KDE de la orquestación ya existente
> en `sunshine-hyprland-virtual-display`.

## Objetivo

Cerrar tres pendientes que el MVP dejó abiertos:

1. **Bug del cursor fantasma:** al desconectar el cliente, el mouse y las ventanas
   pueden seguir yendo al display virtual. No debería existir un segundo monitor
   cuando no hay cliente.
2. **Migrar la sesión al conectar:** al conectar un cliente, las ventanas del
   monitor físico deben pasar al display virtual y el físico quedar **desactivado**
   (modelo headless), como en el proyecto Hyprland.
3. **Adoptar la resolución del cliente:** el lienzo capturado debe crearse a la
   resolución/FPS que pide Artemis/Moonlight, no a un fijo `1920x1080`.

Las tres se resuelven con una sola pieza: ligar el ciclo de vida del display
virtual a la conexión del cliente mediante `global_prep_cmd` (do/undo) de Sunshine.

## Decisiones tomadas (no re-litigar)

- **Monitor físico mientras hay cliente conectado: apagado total (headless).** El
  PC no es usable localmente durante la transmisión; toda la sesión vive en el
  display virtual. Al desconectar, todo vuelve al físico.
- **Alcance de la iteración:** orquestación connect/disconnect + resolución
  dinámica + fix de suspensión (S3) + `install.sh` unificado con autostart.
- **Enfoque elegido: A (crear-al-conectar / destruir-al-desconectar)**, validado
  por un spike antes de comprometerlo. Fallback documentado: C (DPMS-off).

## Restricción dura de Sunshine

Sunshine lee `output_name` y lo **cachea al arrancar**; ni SIGHUP ni la API HTTP
lo refrescan. El nombre que asigna `krfb-virtualmonitor` es **determinista**:
siempre `Virtual-<hint>` = `Virtual-SunshineHeadless`. Por eso el modelo A es
viable: aunque el output no exista al arrancar Sunshine, basta con que exista
—con ese mismo nombre— cuando la captura inicia (después de correr el hook `do`).
El spike valida exactamente este timing.

## Arquitectura

```
sunshine-start.sh (login / autostart)
  1. reconcilia estado: fuerza DP-1 enabled; mata krfb huérfano de sesión previa
  2. escribe sunshine.conf: output_name=Virtual-SunshineHeadless, capture=kwin,
     global_prep_cmd(do=sunshine-connect.sh, undo=sunshine-disconnect.sh)
  3. exec sunshine            (output_name NO existe todavía — es correcto)

CLIENTE CONECTA → global_prep_cmd "do" → sunshine-connect.sh
  1. lee SUNSHINE_CLIENT_WIDTH / HEIGHT / FPS (fallback 1920x1080 si vacío)
  2. crea krfb-virtualmonitor @ resolución del cliente (nombre determinista)
  3. inhibe idle/lock/sleep (systemd-inhibit, PID guardado en archivo de estado)
  4. kscreen-doctor output.DP-1.disable
       → KWin reubica solo todas las ventanas + el cursor al único output vivo
  → Sunshine inicia la captura y encuentra el output por nombre

CLIENTE DESCONECTA → global_prep_cmd "undo" → sunshine-disconnect.sh
  1. kscreen-doctor output.DP-1.enable     (SIEMPRE primero, pase lo que pase)
  2. destruye krfb                          → KWin devuelve ventanas a DP-1
  3. libera el inhibidor (mata el systemd-inhibit por PID)
```

## Componentes / archivos

| Archivo | Estado | Responsabilidad |
|---|---|---|
| `scripts/display-backend.sh` | existe, se reusa | crear/descubrir/destruir display virtual a resolución arbitraria (interfaz `create_virtual_display`, `get_virtual_display_name`, `destroy_virtual_display`) |
| `scripts/sunshine-start.sh` | modificar | quitar la creación del display al arranque; reconciliar estado; inyectar `global_prep_cmd`; lanzar Sunshine |
| `scripts/sunshine-connect.sh` | nuevo | hook `do`: crear virtual @cliente, inhibir, desactivar DP-1 |
| `scripts/sunshine-disconnect.sh` | nuevo | hook `undo`: reactivar DP-1, destruir virtual, liberar inhibidor |
| `scripts/sunshine-after-sleep.sh` | nuevo | recuperación post-S3 (dpms on + nudge a DP-1) |
| `scripts/install.sh` | nuevo | copiar scripts a `~/.local/bin`, instalar autostart `.desktop`, abrir puertos UFW, escribir `sunshine.conf` |
| `config/sunshine.conf` | modificar | añadir `global_prep_cmd` do/undo |
| `autostart/sunshine-headless.desktop` | existe | arranque en login |

Cada script es una unidad con un propósito único y se comunica por la interfaz de
`display-backend.sh` y por el archivo de estado en `~/.local/share/`.

## Resolución dinámica del cliente

- Se **elige en el cliente** (Artemis/Moonlight: resolución y FPS deseados).
- El **host la honra**: `sunshine-connect.sh` lee `SUNSHINE_CLIENT_WIDTH/HEIGHT`
  (variables que Sunshine exporta al ejecutar el `do`) y crea el krfb con
  `--resolution ${W}x${H}`.
- Si las variables vienen vacías o `create_virtual_display` falla → fallback
  `1920x1080` y se registra en el log.

## Manejo de errores (regla de oro: nunca dejar el PC ciego)

- `sunshine-disconnect.sh` **re-habilita DP-1 antes que nada**, aunque cualquier
  paso posterior falle. Idempotente y defensivo.
- Si `sunshine-connect.sh` no logra crear el virtual → **no** desactiva DP-1
  (no deja la pantalla local a oscuras); loguea y deja que Sunshine falle limpio.
- **Reconciliación en `sunshine-start.sh`**: al login fuerza DP-1 enabled y mata
  cualquier krfb huérfano — recupera de un `disconnect` que no llegó a correr
  (p. ej. crash de Sunshine o reinicio en caliente).
- Todo el rastro a `~/.local/share/sunshine-headless.log`.

## Spike de validación (gate antes de implementar A)

Script manual, ejecutado con el usuario presente, con **auto-revert temporizado**
(`trap` + `disable; sleep 5; enable`) para no dejar la sesión sin pantalla. Valida:

- **Spike-1 (timing del cache):** Sunshine arrancado con un `output_name`
  inexistente, ¿captura correctamente el output cuando el hook `do` lo crea?
- **Spike-2 (última salida):** `kscreen-doctor output.DP-1.disable` dejando **solo**
  el output virtual de krfb, ¿KWin lo acepta y reubica ventanas + cursor?

Resultado:
- Ambos pasan → se implementa A completo.
- Spike-2 falla → fallback **C**: DPMS-off de DP-1 (queda como output encendido,
  panel negro) + migración explícita de ventanas vía scripting de KWin (DBus).
  Inconveniente conocido: el cursor podría alcanzar DP-1, a mitigar con confinamiento.

## Testing

- **Spike** (manual, con el usuario).
- **Backend aislado** (ya disponible): crear/descubrir/destruir el virtual.
- **End-to-end** con cliente real, verificando:
  1. la resolución del stream = la pedida por el cliente,
  2. la pantalla local queda apagada durante la sesión,
  3. al desconectar, las ventanas vuelven a DP-1 y el cursor ya **no** alcanza un
     monitor fantasma.

## Fix de suspensión (S3)

Equivalente KDE del `sunshine-after-sleep.sh` de Hyprland. En el modelo A el riesgo
es menor (el virtual solo existe durante la conexión), así que el foco es dejar
DP-1 sano tras el resume: `kscreen-doctor` dpms on + un nudge para forzar repintado.
Se engancha al ciclo de sleep del sistema (systemd `sleep.target`/PowerDevil) según
lo que resulte fiable en KDE; el detalle exacto se fija en el plan de implementación.

## Instalación

`install.sh` para KDE: copia los scripts a `~/.local/bin`, instala el autostart
`.desktop` en `~/.config/autostart`, abre los puertos de Sunshine en UFW si está
activo, y escribe `sunshine.conf` (sin sobrescribir si el usuario ya la personalizó,
avisando que revise el `global_prep_cmd`).

## Futuro / fuera de alcance (backlog)

- **GUI de comportamiento del monitor principal:** un selector para que el usuario
  elija, sin tocar scripts, si su monitor físico debe **permanecer apagado
  (headless)** o **seguir encendido/usable** mientras hay cliente conectado. Hoy el
  comportamiento es fijo (headless). Implica parametrizar `sunshine-connect.sh` y
  `sunshine-disconnect.sh` por una preferencia leída de un archivo de config que la
  GUI escribiría.
- `install.sh` unificado con detección de entorno (Hyprland vs KDE) entre ambos repos.
