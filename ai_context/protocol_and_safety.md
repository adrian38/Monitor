# Protocolo y seguridad operativa

## Snapshot

Ruta lógica: `CopyMonitorMulti\CM_<channel>.txt` dentro de `FILE_COMMON`.

Orden de registros:

1. `META|version|written|channel|nick|account|open_total|pending_total|broker|connected|session`
2. `POS|ticket|symbol|type|volume|open_price|sl|tp`, repetible
3. `ORD|ticket|symbol|type|volume|open_price|sl|tp|stoplimit`, repetible
4. `END`

El separador es `|`, los saltos son CRLF y los valores textuales se sanean
antes de escribir. Cualquier evolución del esquema debe mantener compatibilidad
o actualizar Master y Slave conjuntamente.

El esquema vigente es el `5`:

- el `2` añadió al final del `META` el bróker del Master (`ACCOUNT_COMPANY`);
- el `3` añade al final del registro `ORD` el precio stop-limit de la orden
  (`0` cuando el tipo no lo usa), que hacía falta para comparar y reproducir
  una copia de tipo STOP LIMIT;
- el `4` añade al final del `META` el campo `connected`, que vale `1` cuando el
  terminal Master mantiene la conexión con su servidor de trading;
- el `5` añade al final del `META` una identidad de sesión distinta en cada
  `OnInit` del Master.

`connected` existe porque era el único fallo indistinguible del funcionamiento
normal. Un terminal Master desconectado conserva sus colecciones tal como
estaban y el EA las sigue publicando cada segundo: el snapshot era fresco, su
contenido era pasado, y el Slave no tenía forma de separar «todo cuadra» de
«llevo cuarenta minutos ciego». Lo que el Slave no puede deducir tiene que
viajar en el propio snapshot. La identidad de sesión resuelve el caso análogo
del reinicio: `written` suele seguir creciendo después de reiniciar, así que no
puede demostrar por sí solo que la fuente cambió. Ver
[robustness.md](robustness.md).

El lector acepta `1`, `2`, `3`, `4` y `5`, un único `META`, un `END`, el orden
`META` → `POS*` → `ORD*` → `END` y recuentos declarados que coincidan
exactamente con los registros. Rechaza tipos desconocidos, líneas fuera de
orden y campos básicos imposibles. Con un
Master de esquema `1` el bróker llega vacío y se muestra `NO DISPONIBLE`; con
`1` o `2` el precio stop-limit llega como `0` y no se compara; con `1`, `2` o
`3` el enlace del Master llega como desconocido, el panel lo dice y no se avisa
de lo que no se sabe. Con esquemas `1` a `4` falta la identidad de sesión: el
Slave puede monitorizar, pero no crea, modifica ni borra automáticamente. Un
`META` de esquema `5` sin sus once campos se trata como lectura parcial, no
como contrato distinto. Cualquier campo nuevo se añade al final para no romper
al lector nuevo.

Un snapshot parcial o incoherente queda inválido y suspende las comparaciones y
el borrado de pendientes; se reintenta la lectura antes de darlo por perdido.
Un esquema que el Slave no entiende, o un fichero que declara otro canal, no es
una incidencia transitoria sino el contrato roto: se avisa siempre como
`CRÍTICO`, con independencia de `InpNotifySnapshotProblems`. Por eso un Master
más nuevo nunca deja la vigilancia parada en silencio, pero **Master y Slave se
despliegan juntos**: un Slave anterior rechaza el esquema `5`.

Una ausencia de datos sostenida tampoco es silenciosa desde la v1.25:
`InpNotifySnapshotProblems` gobierna sólo la falta transitoria, y pasados
`InpStaleAlertSeconds` el aviso es obligatorio. Un Master muerto, un VPS
reiniciado o un disco lleno dejaban al Slave suspendiendo todas las
comparaciones sin decir nada, que es justo lo contrario de lo que debe hacer un
monitor. Lo mismo vale para el Master desconectado (`MOFF`) y para el propio
terminal Slave desconectado (`SOFF`): en los tres casos la comparación y las
correcciones se suspenden, porque actuar sobre datos congelados es peor que no
actuar, y en los tres casos se avisa.

El identificador de canal admite de 1 a 32 caracteres de `A-Z a-z 0-9 _ - .` en
ambos EAs, porque los dos derivan el nombre del fichero con la misma regla.
Ver [robustness.md](robustness.md).

## Matching y ownership

- Single-master puede usar un comentario Slave vacío sólo si todas las
  correcciones automáticas están desactivadas; multi-master exige siempre un
  comentario propietario no vacío y único por canal.
- Cualquier corrección automática exige además una cuenta Master esperada por
  canal. Comentario y cuenta forman la frontera de propiedad antes de tocar el
  Slave; en modo sólo monitor siguen siendo opcionales.
- Las equivalencias de símbolo son específicas del canal y deben estar bien
  formadas: una entrada incompleta detiene el arranque en lugar de descartarse.
- La tolerancia de volumen se expresa en pasos de volumen del símbolo Slave.
- El emparejamiento no depende del orden de las colecciones del terminal: los
  dos lados se recorren por ticket ascendente sólo para que la evaluación sea
  reproducible. Una pareja debe ser única en ambos sentidos: el Master sólo
  puede tener una candidata y esa Slave sólo puede identificar a una Master
  libre. Ningún empate se resuelve por ticket u orden de apertura. Dos entradas
  gemelas intentan identificarse antes por los valores que el Slave compara y,
  si siguen siendo ambiguas, se avisa sin corregir. Ver
  [ambiguous_matching.md](ambiguous_matching.md).
- Precio de entrada, SL y TP se comparan sólo cuando sus opciones están activas.
  El precio stop-limit se compara cuando el Master lo publica.
- Los tickets Master configurados para ignorar no generan incidencias.
- Los comentarios Slave configurados para ignorar se comparan de forma exacta
  y quedan fuera del ownership, el matching, las correcciones y el recuento
  agregado. La exclusión por comentario prevalece sobre los demás filtros.

### Lo que el canal no ve

Al construir sus listas el Slave descarta en silencio toda operación cuyo
símbolo quede fuera del filtro o cuyo comentario no sea el del canal. Es
deliberado, pero dejaba un descuadre sin explicación: el usuario contaba cinco
operaciones en el Master y cuatro en el Slave y ningún aviso decía por qué.

`CheckCounts` cierra ese hueco. Recorre el terminal entero una vez por ciclo y
por canal, y emite `COUNT|<canal>` cuando la diferencia de cantidades no está
ya cubierta por un aviso por operación. Cuenta como **explicada** la operación
que pertenece a otro canal configurado en el mismo EA, porque en multi-master
eso es lo normal. Cuentan como **inexplicadas**:

- la operación de este canal oculta por el filtro de símbolos;
- la operación que no pertenece a ningún canal configurado;
- la posición Master cuyo símbolo Slave está filtrado, que nunca podrá tener
  copia visible y genera un aviso de copia faltante incomprensible;
- la posición Slave sin pareja Master en los perfiles que no avisan de
  posiciones extra, es decir todos menos `PORTFOLIO46`.

El aviso es `AlertOnChange`: no repite recordatorio por ciclo, pero se reenvía
cada vez que alguna de las cifras cambia, con el recuento de ambos lados y el
motivo de cada diferencia, y cierra con `RESUELTO` cuando todo vuelve a
cuadrar. En perfil `GENERIC` sin comentario propietario el EA no puede
distinguir sus copias de una operación manual, así que una operación abierta a
mano en el Slave entra como inexplicada: la palanca es el comentario de
propiedad. Ver [alert_lifecycle.md](alert_lifecycle.md).

## Límites de automatización

- El Master nunca abre, modifica ni cierra operaciones.
- El Slave nunca abre, cierra ni cambia el volumen de posiciones abiertas.
- El Slave puede modificar SL/TP de posiciones y crear o modificar pendientes
  sólo después de que la discrepancia persista y se revalide. Inmediatamente
  antes de toda acción se vuelve a leer un snapshot fresco de esquema `5` y se
  confirman la misma cuenta, sesión y valores Master. Crear reconcilia además
  la cuenta Slave y borrar vuelve a validar el criterio aplicable a la copia.
- Una pendiente sólo se borra si pertenece al owner evaluado, sigue siendo
  extra y permanece así durante el tiempo de confirmación. En MT5
  `InpEmptyMasterConfirmSeconds` se aplica a la ausencia de su ticket Master
  vinculado y de alternativas compatibles. En MT4 se aplica al canal vacío.
- Una copia que existe con otro volumen no es una copia faltante: se avisa como
  `POSVOL` o `PVOL` y **nunca** se responde creando una segunda. El volumen de
  una posición no se corrige jamás; el de una pendiente tampoco, porque
  ajustarle el precio afianzaría una copia del tamaño equivocado.
- Las acciones automáticas están acotadas por canal y por hora
  (`InpMaxAutoActionsPerHour`): si la copiadora deshace lo que hace el monitor,
  el ping-pong se corta con un `BLOQUEADO` en lugar de seguir indefinidamente.
- Ninguna corrección se intenta sin permiso de trading del terminal, del EA y
  de la cuenta, ni con precios o volúmenes que el bróker deba rechazar: esos
  casos se informan como `BLOQUEADO` sin tocar la cuenta.
- Una copia sólo se crea sobre un símbolo permitido y disponible, y se verifica
  que la orden creada es visible como propia y emparejable. Si no lo es, se
  avisa y se bloquea el reintento para no duplicar pendientes.
- Un resultado de creación indeterminado (timeout, conexión perdida o error
  común) se reconcilia con las órdenes vivas. Si no aparece exactamente una
  copia propia compatible, se bloquea el reintento para revisión manual. El
  bloqueo se persiste y sobrevive a reinicios; no caduca por tiempo.
- No probar borrado, WebRequest de Telegram ni interacción con una cuenta real
  sin autorización explícita del usuario.
