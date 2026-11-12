# AI context de Monitor

Índice del contexto técnico duradero de los Expert Advisors CopyMonitor.
Antes de tocar un área, buscar el tema en esta carpeta y leer la nota relevante.

- [architecture.md](architecture.md): responsabilidades de Master y Slave,
  transporte por snapshot y flujo de ejecución.
- [protocol_and_safety.md](protocol_and_safety.md): contrato del archivo
  compartido, identidad de sesión, ownership, matching y límites de
  automatización y exclusiones explícitas en el aviso `COUNT`.
- [development.md](development.md): flujo de edición, versionado y verificación.
- [pending_matching.md](pending_matching.md): emparejamiento uno a uno de
  pendientes, detección de faltantes y borrado por pareja de tickets en las dos
  plataformas, incluso para pendientes del mismo símbolo y tipo distinguibles
  por valores.
- [ambiguous_matching.md](ambiguous_matching.md): desempate por valores cuando
  dos posiciones o pendientes gemelas son indistinguibles en el snapshot y
  unicidad del enlace en ambos sentidos, incluso con una sola copia y un
  ticket ignorado en MT5, y al revalidar creaciones MT5.
- [copiix_log_matching.md](copiix_log_matching.md): identidad exacta de las
  copias con Journals y logs de Experts de Copiix en MT5. Desde la v1.37 el
  Slave lanza el auxiliar y el índice enlaza con autoridad operativa.
- [telegram_messages.md](telegram_messages.md): formato humano unificado,
  identificadores de cuenta, datos operativos, alerta de recuentos y avisos de
  creación desactivada.
- [alert_lifecycle.md](alert_lifecycle.md): una clave por problema, quién envía
  el `RESUELTO` y cómo se cierran los avisos de un ticket que ya no existe.
- [automatic_corrections.md](automatic_corrections.md): alcance autorizado,
  persistencia, revalidación y mensajes de resolución de los arreglos.
- [robustness.md](robustness.md): publicación atómica, lectura reintentada,
  validación de configuración, cola de avisos, estado persistente y
  revalidación inmediatamente anterior a corregir.
- [terminal_watchdog.md](terminal_watchdog.md): vigilancia de conexión del
  terminal MT4, confirmación de la caída, recordatorios y límite del vigilante.
- [mt4_port.md](mt4_port.md): port MT4 de Master y Slave, equivalencia de
  códigos de tipo, interoperabilidad entre plataformas y lo propio de MQL4.

El código es la autoridad sobre los detalles que no estén documentados aquí.
Toda decisión duradera nueva debe añadirse a una nota temática y a este índice.

