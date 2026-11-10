# AI context de Monitor

Índice del contexto técnico duradero de los Expert Advisors CopyMonitor.
Antes de tocar un área, buscar el tema en esta carpeta y leer la nota relevante.

- [architecture.md](architecture.md): responsabilidades de Master y Slave,
  transporte por snapshot y flujo de ejecución.
- [protocol_and_safety.md](protocol_and_safety.md): contrato del archivo
  compartido, ownership, matching y límites de automatización.
- [development.md](development.md): flujo de edición, versionado y verificación.
- [pending_matching.md](pending_matching.md): emparejamiento uno a uno de
  pendientes, detección de faltantes y política conservadora de borrado.
- [ambiguous_matching.md](ambiguous_matching.md): desempate por valores cuando
  dos posiciones o pendientes gemelas son indistinguibles en el snapshot.
- [telegram_messages.md](telegram_messages.md): formato humano unificado,
  identificadores de cuenta y datos operativos exigidos en cada aviso.
- [automatic_corrections.md](automatic_corrections.md): alcance autorizado,
  persistencia, revalidación y mensajes de resolución de los arreglos.
- [robustness.md](robustness.md): publicación atómica, lectura reintentada,
  validación de configuración, cola de avisos y guardas previas a corregir.
- [terminal_watchdog.md](terminal_watchdog.md): vigilancia de conexión del
  terminal MT4, confirmación de la caída, recordatorios y límite del vigilante.
- [mt4_port.md](mt4_port.md): port MT4 de Master y Slave, equivalencia de
  códigos de tipo, interoperabilidad entre plataformas y lo propio de MQL4.

El código es la autoridad sobre los detalles que no estén documentados aquí.
Toda decisión duradera nueva debe añadirse a una nota temática y a este índice.

