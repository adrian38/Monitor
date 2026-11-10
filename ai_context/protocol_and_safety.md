# Protocolo y seguridad operativa

## Snapshot

Ruta lógica: `CopyMonitorMulti\CM_<channel>.txt` dentro de `FILE_COMMON`.

Orden de registros:

1. `META|version|written|channel|nick|account|open_total|pending_total|broker`
2. `POS|ticket|symbol|type|volume|open_price|sl|tp`, repetible
3. `ORD|ticket|symbol|type|volume|open_price|sl|tp|stoplimit`, repetible
4. `END`

El separador es `|`, los saltos son CRLF y los valores textuales se sanean
antes de escribir. Cualquier evolución del esquema debe mantener compatibilidad
o actualizar Master y Slave conjuntamente.

El esquema vigente es el `3`:

- el `2` añadió al final del `META` el bróker del Master (`ACCOUNT_COMPANY`);
- el `3` añade al final del registro `ORD` el precio stop-limit de la orden
  (`0` cuando el tipo no lo usa), que hacía falta para comparar y reproducir
  una copia de tipo STOP LIMIT.

El lector acepta `1`, `2` y `3`, un único `META`, un `END` y recuentos
declarados que coincidan exactamente con los registros `POS` y `ORD`. Con un
Master de esquema `1` el bróker llega vacío y se muestra `NO DISPONIBLE`; con
`1` o `2` el precio stop-limit llega como `0` y no se compara. Cualquier campo
nuevo se añade al final para no romper al lector antiguo.

Un snapshot parcial o incoherente queda inválido y suspende las comparaciones y
el borrado de pendientes; se reintenta la lectura antes de darlo por perdido.
Un esquema que el Slave no entiende, o un fichero que declara otro canal, no es
una incidencia transitoria sino el contrato roto: se avisa siempre como
`CRÍTICO`, con independencia de `InpNotifySnapshotProblems`. Por eso un Master
más nuevo nunca deja la vigilancia parada en silencio, pero **Master y Slave se
despliegan juntos**: un Slave anterior rechaza el esquema `3`.

El identificador de canal admite de 1 a 32 caracteres de `A-Z a-z 0-9 _ - .` en
ambos EAs, porque los dos derivan el nombre del fichero con la misma regla.
Ver [robustness.md](robustness.md).

## Matching y ownership

- Single-master puede usar un comentario Slave vacío; multi-master exige un
  comentario propietario no vacío y único por canal.
- Las equivalencias de símbolo son específicas del canal y deben estar bien
  formadas: una entrada incompleta detiene el arranque en lugar de descartarse.
- La tolerancia de volumen se expresa en pasos de volumen del símbolo Slave.
- El emparejamiento no depende del orden de las colecciones del terminal: los
  dos lados se recorren por ticket ascendente y un empate lo gana el ticket más
  bajo. Dos entradas gemelas se desempatan antes por los valores que el Slave
  compara. Ver [ambiguous_matching.md](ambiguous_matching.md).
- Precio de entrada, SL y TP se comparan sólo cuando sus opciones están activas.
  El precio stop-limit se compara cuando el Master lo publica.
- Los tickets Master configurados para ignorar no generan incidencias.

## Límites de automatización

- El Master nunca abre, modifica ni cierra operaciones.
- El Slave nunca abre, cierra ni cambia el volumen de posiciones abiertas.
- El Slave puede modificar SL/TP de posiciones y crear o modificar pendientes
  sólo después de que la discrepancia persista y se revalide.
- Una pendiente sólo se borra si pertenece al owner evaluado, sigue siendo
  extra y permanece así durante el tiempo de confirmación.
- Ninguna corrección se intenta sin permiso de trading del terminal, del EA y
  de la cuenta, ni con precios o volúmenes que el bróker deba rechazar: esos
  casos se informan como `BLOQUEADO` sin tocar la cuenta.
- Una copia sólo se crea sobre un símbolo permitido y disponible, y se verifica
  que la orden creada es visible como propia y emparejable. Si no lo es, se
  avisa y se bloquea el reintento para no duplicar pendientes.
- No probar borrado, WebRequest de Telegram ni interacción con una cuenta real
  sin autorización explícita del usuario.
