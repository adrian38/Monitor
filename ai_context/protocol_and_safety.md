# Protocolo y seguridad operativa

## Snapshot

Ruta lógica: `CopyMonitorMulti\CM_<channel>.txt` dentro de `FILE_COMMON`.

Orden de registros:

1. `META|version|written|channel|nick|account|open_total|pending_total`
2. `POS|ticket|symbol|type|volume|open_price|sl|tp`, repetible
3. `ORD|ticket|symbol|type|volume|open_price|sl|tp`, repetible
4. `END`

El separador es `|`, los saltos son CRLF y los valores textuales se sanejan
antes de escribir. Cualquier evolución del esquema debe mantener compatibilidad
o actualizar Master y Slave conjuntamente.

## Matching y ownership

- Single-master puede usar un comentario Slave vacío; multi-master exige un
  comentario propietario no vacío y único por canal.
- Las equivalencias de símbolo son específicas del canal.
- La tolerancia de volumen se expresa en pasos de volumen del símbolo Slave.
- Precio de entrada, SL y TP se comparan sólo cuando sus opciones están activas.
- Los tickets Master configurados para ignorar no generan incidencias.

## Límites de automatización

- El Master nunca abre, modifica ni cierra operaciones.
- El Slave nunca cierra posiciones abiertas automáticamente.
- Una pendiente sólo se borra si pertenece al owner evaluado, sigue siendo
  extra y permanece así durante el tiempo de confirmación.
- No probar borrado, WebRequest de Telegram ni interacción con una cuenta real
  sin autorización explícita del usuario.

