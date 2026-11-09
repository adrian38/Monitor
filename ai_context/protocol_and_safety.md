# Protocolo y seguridad operativa

## Snapshot

Ruta lógica: `CopyMonitorMulti\CM_<channel>.txt` dentro de `FILE_COMMON`.

Orden de registros:

1. `META|version|written|channel|nick|account|open_total|pending_total|broker`
2. `POS|ticket|symbol|type|volume|open_price|sl|tp`, repetible
3. `ORD|ticket|symbol|type|volume|open_price|sl|tp`, repetible
4. `END`

El separador es `|`, los saltos son CRLF y los valores textuales se sanejan
antes de escribir. Cualquier evolución del esquema debe mantener compatibilidad
o actualizar Master y Slave conjuntamente.

El esquema vigente es el `2`: añade al final del `META` el bróker del Master
(`ACCOUNT_COMPANY`). El lector acepta `1` y `2`, un único `META`, un `END` y
recuentos declarados que coincidan exactamente con los registros `POS` y `ORD`.
Con un Master de esquema `1` el bróker llega vacío y se muestra
`NO DISPONIBLE`; cualquier campo nuevo se añade al final para no romper al
lector antiguo.
Un snapshot parcial o incoherente queda inválido y suspende las comparaciones y
el borrado de pendientes.

## Matching y ownership

- Single-master puede usar un comentario Slave vacío; multi-master exige un
  comentario propietario no vacío y único por canal.
- Las equivalencias de símbolo son específicas del canal.
- La tolerancia de volumen se expresa en pasos de volumen del símbolo Slave.
- Precio de entrada, SL y TP se comparan sólo cuando sus opciones están activas.
- Los tickets Master configurados para ignorar no generan incidencias.

## Límites de automatización

- El Master nunca abre, modifica ni cierra operaciones.
- El Slave nunca abre, cierra ni cambia el volumen de posiciones abiertas.
- El Slave puede modificar SL/TP de posiciones y crear o modificar pendientes
  sólo después de que la discrepancia persista y se revalide.
- Una pendiente sólo se borra si pertenece al owner evaluado, sigue siendo
  extra y permanece así durante el tiempo de confirmación.
- Una copia sólo se crea sobre un símbolo permitido y disponible, y se verifica
  que la orden creada es visible como propia. Si no lo es, se avisa y se
  bloquea el reintento para no duplicar pendientes.
- No probar borrado, WebRequest de Telegram ni interacción con una cuenta real
  sin autorización explícita del usuario.

