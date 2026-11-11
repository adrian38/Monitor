# Robustez operativa

Decisiones tomadas para que un fallo del entorno no deje al monitor mudo ni le
haga actuar a ciegas. Son contrato: no se deben revertir sin sustituirlas.

## Lo que el Slave no puede deducir

Hasta la v1.24 el monitor confiaba en una premisa que nadie comprobaba: que un
snapshot fresco contenía la realidad del Master. No era cierto en tres casos, y
los tres se arreglan en la v1.25 del Slave MT5 y la v1.05 del Slave MT4.

**El Master desconectado de su servidor.** Un terminal sin conexión conserva
sus colecciones tal como estaban y el EA las publica cada segundo. El snapshot
era fresco, el Slave lo daba por bueno y no avisaba de nada mientras el Master
podía llevar cuarenta minutos sin recibir un solo cambio. Era el único fallo
indistinguible del funcionamiento normal. El esquema 4 añade `connected` al
`META`. Comparación y correcciones se suspenden desde la primera lectura con
`connected=0`; `InpMasterOfflineConfirmSeconds` sólo retrasa el `MOFF`
`CRÍTICO` para no avisar por una microdesconexión.

**La ausencia de datos sostenida.** `InpNotifySnapshotProblems` sigue
gobernando la falta transitoria, pero pasados `InpStaleAlertSeconds` el aviso
es obligatorio. El razonamiento ya estaba escrito para el esquema roto —«un
Master más nuevo no puede dejar la vigilancia parada en silencio»— y se aplica
entero a un Master muerto. Con el valor por defecto, antes el EA callaba.

**El propio terminal Slave desconectado.** `PositionsTotal()` devuelve la foto
cacheada, así que el EA comparaba contra el pasado y podía intentar
correcciones que fallaban con un retcode incomprensible. Ahora `SlaveLinkOk()`
suspende el ciclo desde el primer estado desconectado;
`InpSlaveOfflineConfirmSeconds` sólo confirma el `SOFF`. Los snapshots se
siguen leyendo para el panel.

Al volver la conexión tampoco se confía en la primera foto cacheada. Tanto el
enlace Slave como cada canal Master deben permanecer sanos durante
`InpLinkRecoverySeconds` antes de reanudar comparación o correcciones. Cualquier
snapshot ausente, parcial, obsoleto, cruzado, de otra cuenta o desconectado
reinicia esa confianza y las confirmaciones para borrar pendientes.

La v1.27/v1.07 añade la identidad de sesión del esquema 5. Comparar sólo
`written` detectaba un salto de reloj hacia atrás, pero no un reinicio normal:
la hora seguía creciendo y la confirmación previa podía sobrevivir al nuevo
Master. Cada `OnInit` publica un ID nuevo; el cambio invalida la confianza y
las confirmaciones. En MT5 también se descartan los vínculos de pendientes
observados. Los esquemas anteriores se siguen leyendo para
monitorización, pero no autorizan ninguna acción automática.

En los tres casos se suspende en lugar de seguir comparando: actuar sobre datos
que se sabe congelados es peor que no actuar, y el usuario recibe el aviso.

## Quién vigila al vigilante

El EA que debería avisar de que ha muerto es precisamente el que ha muerto, así
que el silencio era ambiguo. Dos añadidos lo resuelven sin inventar
infraestructura:

- `InpSendStartupNotice` envía un `VIGILANCIA ACTIVA` en el primer ciclo, con
  el resumen por canal. Es la única forma de saber que Telegram funciona antes
  de que haya un incidente real; el vigilante MT4 ya lo tenía.
- `InpHeartbeatHours` repite ese resumen cada N horas. A partir de ahí, no
  recibir nada deja de significar «todo bien» por omisión.

## Telegram no puede ser el único camino

Sin `api.telegram.org` en la whitelist de WebRequest todos los envíos fallan
para siempre y sólo queda el panel, que nadie mira. `InpEnablePushFallback`
añade `SendNotification`, que no depende de esa whitelist:

- un `CRÍTICO` que no va a salir pronto —hay cola, o el backoff está en curso—
  se duplica por push con su cabecera;
- cada descarte por cola llena sale por push, como mucho uno cada
  `InpMismatchReminderSeconds` para que una tormenta no genere una
  notificación por mensaje perdido;
- el latido y el aviso de arranque usan push cuando Telegram no está
  configurado.

Además, lo que se perdió por cola llena ya no desaparece sin más. `AlertOnce`,
`AlertOnChange` y todos los `RESUELTO` se envían una sola vez, así que un
descarte los borraba para siempre: `TGDROP` es un `PersistAlert` que cuenta
cuántos avisos no llegaron y se resuelve cuando la cola vuelve a vaciarse.

## La detección precede a la espera de red

Hasta la v1.24 `Tg()` publicaba en línea cuando la cola estaba vacía, y cada
POST bloquea hasta `InpTelegramTimeoutMs`. Con una tormenta de avisos el ciclo
se alargaba justo cuando más rápido había que detectar. Ahora todo aviso entra
en la cola y sale en `TgFlush`, al final del ciclo y acotado por
`InpTelegramSendsPerCycle`. `WebRequest` sigue siendo síncrono, de modo que el
temporizador puede tardar hasta el timeout por envío, pero la detección y las
correcciones de ese ciclo ya han terminado. La cola sigue siendo FIFO estricta,
así que el orden `ALERTA` → `RESUELTO` se conserva.

La cola se persiste en `CM_TGQUEUE_<SlaveID>.txt` cuando también se persiste el
estado de avisos. Así, un reinicio no pierde un `ALERTA` o `RESUELTO` que ya se
había generado pero aún no había llegado a Telegram.

## Publicación del snapshot

- El Master construye primero las filas `POS` y `ORD` y deriva de ellas los
  totales del `META`. Contarlos en una pasada aparte permitía publicar un
  `META` incoherente con los registros y el Slave invalidaba todo el snapshot.
- Se escribe en `CM_<channel>.tmp` y se renombra sobre `CM_<channel>.txt`. Si
  el renombrado falla porque el lector tiene el fichero abierto, se escribe
  directamente sobre el destino: perder la publicación es peor que una lectura
  rota, que el Slave ya detecta.
- El fichero se abre con `FILE_SHARE_READ`, de modo que el Slave nunca recibe
  un fallo de apertura mientras el Master escribe.
- Las colecciones se recorren hacia atrás: si el terminal retira una entrada
  durante el recorrido, los índices ya visitados no se desplazan.

## Lectura del snapshot

- Una lectura puede coincidir con la reescritura. El contenido parcial se
  detecta siempre por contadores y por la marca `END`, así que se reintenta
  hasta tres veces dentro del mismo ciclo antes de declarar que no hay datos.
- El parser exige el orden lineal `META`, `POS*`, `ORD*`, `END`, un único
  encabezado y fin, tipos de registro conocidos y valores básicos válidos
  (ticket, símbolo, tipo, volumen, precio, totales y conexión). Una línea
  desconocida o fuera de orden invalida la foto en vez de aceptar media verdad.
- Se distingue el tipo de problema: ausencia o lectura parcial es transitoria y
  la gobierna `InpNotifySnapshotProblems`; un esquema desconocido o un canal
  cruzado son contrato roto y se avisan **siempre** como `CRÍTICO`. Un Master
  más nuevo que el Slave no puede dejar la vigilancia parada en silencio.
- El adelanto del reloj admitido es `InpClockSkewToleranceSeconds`, un segundo
  por defecto. Era una constante, y con ella una sincronización NTP o dos
  máquinas distintas dejaban el snapshot permanentemente «en el futuro» y la
  vigilancia parada.

## Identificador de canal

Master y Slave derivan el nombre del fichero común con la misma regla, así que
ambos exigen el mismo juego de caracteres: de 1 a 32 de `A-Z a-z 0-9 _ - .`.
Sanear en silencio dejaba dos riesgos reales: un canal con `|` producía un
`META` que el Slave nunca reconocía como propio, y dos canales distintos podían
colapsar en el mismo fichero. La función `ChannelIdValid` debe permanecer
idéntica en los dos EAs; `tools/verify_project.py` compara su cuerpo.

## Configuración

Los parámetros `input` no cambian durante la ejecución, así que las listas de
propietarios, equivalencias de símbolo, tickets ignorados y filtros se resuelven
una sola vez en `OnInit`. Antes se reparseaban dentro de los bucles de
emparejamiento, una división de cadena por símbolo y por ciclo.

Una configuración mal escrita detiene el arranque con un motivo en el log en
lugar de degradarse en silencio: perfil desconocido, equivalencia incompleta,
ticket no numérico, canal inválido, listas multi-master de distinta longitud o
Telegram activado sin token.

Desde la v1.25 el arranque se detiene además en cuatro casos nuevos:

- **Cuenta de compensación.** El emparejamiento supone una copia por posición
  Master, es decir cobertura. En netting dos copias del mismo símbolo se funden
  en una posición con el volumen sumado y el modelo entero se cae: el EA
  avisaría de copias faltantes y de ambigüedades para siempre.
  `InpAllowNettingAccount` permite arrancar de todos modos. MT4 no necesita la
  comprobación porque sus cuentas son siempre de cobertura.
- **Instancia duplicada.** Dos Slave con el mismo `InpSlaveID` comparten
  `CM_ALERTS_<id>.txt` y se lo pisan: el que escribe último borra los avisos
  activos del otro, y con ellos sus `RESUELTO`. El testigo es una variable
  global del terminal que se refresca cada ciclo y se suelta en `OnDeinit`; uno
  que nadie refresca es de una instancia que ya no existe. Además, `OnDeinit`
  sólo guarda avisos, cola y bloqueos si esa instancia llegó a adquirir el lock
  y cargar su estado: un `OnInit` rechazado nunca puede sobrescribir con arrays
  vacíos los ficheros del dueño legítimo.
- **Comentario propietario demasiado largo** (más de 31 caracteres). El port
  MT4 ya lo comprobaba; el MT5 dejaba crear copias que nunca volvían a
  reconocerse como propias.
- **Modo de propiedad ambiguo.** Con `InpOwnerMatchMode` en `PREFIX` o
  `CONTAINS`, dos comentarios distintos pueden reclamar la misma operación. Si
  eso ocurre no hay propiedad que decidir, así que no se reparte por el orden
  de la lista: se para.

`InpExpectedMasterAccounts` es opcional y posicional con los canales. Sin él,
cambiar el login del terminal Master conservando el canal dejaba al Slave
vigilando otra cuenta sin decir una palabra; con él se emite `MACCOUNT` como
`CRÍTICO` y se suspende la comparación. Una lista parcial se rechaza: el
usuario creería estar vigilando lo que no está.

`InpSymbolTolerances` declara excepciones `SIMBOLO,entrada,sltp,pendiente` a
las tolerancias globales. Un único valor en puntos para toda la cuenta es o
muchísimo o nada cuando conviven oro, índices y divisas, y una tolerancia
demasiado estrecha no relaja nada: rompe el emparejamiento y convierte una
copia correcta en una copia faltante permanente. El símbolo puede ser el nombre
Master o el Slave de `InpSymbolMaps`: el comparador resuelve el alias hacia el
símbolo Slave. Una entrada escrita directamente con el nombre Slave tiene
prioridad; sin ella, dos alias Master del mismo símbolo Slave con valores
distintos invalidan la configuración en vez de depender del orden de la lista.

Dos cambios pueden rechazar una configuración que antes arrancaba:

- un `InpMasterChannel` o un `InpMasterChannels` con espacios u otros
  caracteres fuera del juego permitido;
- `InpEnableTelegram` activado sin token o sin chat ID.

`InpVolumeToleranceSteps` se respeta tal cual: antes un cero se trataba como
uno, lo que contradecía la documentación. Con cero la comparación de volumen es
exacta salvo el ruido de coma flotante.

La v1.26/v1.06 endurece además la identidad de cualquier instancia que vaya a
corregir: cada owner necesita comentario no vacío y cuenta Master esperada. Un
comentario vacío equivale a reclamar todas las órdenes y no es una propiedad
segura para crear, modificar o borrar. Esas dos condiciones siguen siendo
opcionales en un Slave puramente observador.

`InpSlaveID` sólo admite de 1 a 32 caracteres `A-Z a-z 0-9 _ -`; no se sanea
en silencio porque dos IDs distintos podían colapsar en los mismos ficheros y
variables globales. La exclusión de instancia mantiene un fichero exclusivo en
`FILE_COMMON`, que cubre terminales MT4 y MT5 distintos, y dentro de cada
terminal usa adquisición atómica con token y latido separado. `OnDeinit` libera
únicamente el token que posee, por lo que un segundo EA cuyo `OnInit` falla
nunca puede borrar el lock del primero. El plazo de abandono incluye el peor
bloqueo configurado de Telegram y los reintentos de lectura.

Cada Master mantiene además abierto en exclusiva
`CopyMonitorMulti\CM_<channel>.lock` durante toda su vida. MT4 y MT5 comparten
`FILE_COMMON`, así que un segundo publicador del mismo canal en la máquina no
arranca y no puede alternar dos cuentas bajo un solo nombre.

Si el envío de una pendiente devuelve timeout, pérdida de conexión o error
común, el resultado es indeterminado: antes de decidir se busca una única orden
propia compatible. Si no puede demostrarse éxito o fracaso, el ticket Master
queda bloqueado para revisión manual; reintentar a ciegas podría duplicarlo.
Los bloqueos se escriben atómicamente en
`CM_CREATEBLOCKS_<InpSlaveID>.txt`, aunque `InpPersistAlertState` esté
desactivado; no caducan por el TTL general y sobreviven a recompilaciones,
recargas y reinicios. Sólo se retiran cuando el matching ya demuestra una copia
compatible o el ticket Master desaparece.

La misma versión cierra la carrera entre comprobar y actuar. Justo antes de
modificar se confirma que la posición u orden Master no cambió; antes de crear
se hace lo mismo y se busca otra vez una copia propia compatible; antes de
borrar se comprueba otra vez la ausencia de la orden vinculada en MT5 o el
canal vacío en MT4. Todas las rutas exigen
snapshot de esquema 5, misma cuenta y sesión, enlace sano y ventana de
recuperación. Si algo cambia, se bloquea esa acción y el ciclo siguiente
reconstruye el diagnóstico.

El matching también es bidireccional. Una Master con una sola candidata no se
asigna si esa Slave puede explicar otra Master libre; esta regla se aplica al
desempate por valores, al matching principal y a la pasada que ignora volumen.
En pendientes, la ambigüedad protege la candidata frente al borrado y evita
crear otra orden.

## Avisos

- Telegram se envía por `POST`; el texto va en el cuerpo y no depende del
  límite de longitud de una URL.
- Un aviso de más de 3000 caracteres se trocea por líneas. Telegram rechaza
  todo lo que pase de 4096 y el aviso completo se perdía.
- Lo que no sale espera en una cola acotada de 40 trozos y se reintenta en los
  ciclos siguientes, dos por ciclo. Mientras haya cola, lo nuevo también se
  encola para no romper el orden.
- Un aviso sobre un ticket que ya no existe se cierra con `RESUELTO`. Antes
  quedaba activo para siempre: ni se resolvía ni podía caducar.

## Espera tras un envío fallido

Hasta la v1.17 un fallo de Telegram se reintentaba en el ciclo siguiente, es
decir cada segundo con `InpMonitorSeconds=1`. El límite de Telegram es por
token y vive en su servidor, así que cada reintento renovaba la penalización en
lugar de dejarla caducar: un incidente real produjo 648 fallos consecutivos en
14 minutos, alternando `HTTP=429` y `err=5203`, sin un solo envío correcto y
con la cola descartando avisos. `PersistAlert` ya limitaba la *generación* de
avisos por esta razón, pero `TgFlush` reintroducía el problema un nivel más
abajo al vaciar la cola.

- Tras un fallo no se toca la red hasta `g_tg_next_try`, ni para la cola ni
  para un aviso nuevo.
- Un `429` trae en el cuerpo JSON el campo `retry_after`. Se respeta entero,
  aunque supere `InpTelegramRetryMaxSeconds`: volver antes de tiempo es
  exactamente lo que mantiene vivo el bloqueo.
- Sin `retry_after` la espera arranca en `InpTelegramRetryBaseSeconds` y se
  dobla con cada fallo consecutivo hasta `InpTelegramRetryMaxSeconds`.
- Un envío correcto borra la racha y la espera.
- El panel muestra los segundos que faltan para el próximo intento.

La cola sigue siendo FIFO estricta y el desbordamiento descarta lo más antiguo.
Un aviso nuevo espera detrás de los anteriores: es deliberado, porque adelantar
mensajes rompería el orden `ALERTA` → `RESUELTO`.

## Estado de avisos en disco

`g_alerts` vivía sólo en memoria y el EA no escribía ningún fichero. Un
reinicio —recompilar, recargar el gráfico, reiniciar el terminal— borraba qué
problemas estaban avisados, y `ResolveAlert` no encontraba la clave: el
`RESUELTO` de un problema avisado antes del reinicio no se enviaba nunca.

- Los avisos activos se guardan en `CopyMonitorMulti\CM_ALERTS_<InpSlaveID>.txt`
  dentro de la carpeta local del terminal, no en la común: el estado es de esta
  instancia y dos Slave distintos no deben pisarse el fichero. Que no se pisen
  lo garantiza ahora el testigo de instancia, no la buena fe del usuario.
- Se escribe en `.tmp` y se renombra sobre el destino, igual que el snapshot.
  Truncar el fichero bueno y morir a mitad dejaba un estado de avisos
  incoherente, y con él los `RESUELTO` de lo que quedara dentro.
- Se escribe sólo cuando entra o sale un aviso del conjunto activo, y en
  `OnDeinit`. Volcar el fichero al refrescar una marca de tiempo lo reescribiría
  en cada ciclo.
- Se lee en `OnInit` antes del primer ciclo, de modo que un problema que siga
  abierto se reconoce en vez de volver a avisarse.
- `InpPersistAlertState` permite desactivarlo.

## Ajustes expuestos

Todos los temporizadores y límites internos son `input` desde la v1.17, con el
valor que el EA usaba fijo como valor por defecto: `InpStateTTLSeconds`,
`InpSnapshotReadAttempts`, `InpSnapshotReadRetryMs`,
`InpMarketClosedRetrySeconds`, `InpTelegramChunkChars`, `InpTelegramQueueMax`,
`InpTelegramSendsPerCycle` en el Slave, e `InpPublishFailLogSeconds` en el
Master. La v1.19 añade `InpTelegramRetryBaseSeconds`,
`InpTelegramRetryMaxSeconds` e `InpPersistAlertState`. Cada uno se valida en el
arranque con un motivo en el log, y dos de esos límites protegen el ciclo
completo:

- los reintentos de lectura no pueden sumar más de 500 ms por canal, porque la
  pausa bloquea el hilo del EA;
- `InpTelegramSendsPerCycle` por `InpTelegramTimeoutMs` no puede pasar de
  15000 ms, para que vaciar la cola no atasque el ciclo.

`InpTelegramTimeoutMs` pasa de 1200 a 5000 ms en la v1.19. Un POST con TLS a
`api.telegram.org` no siempre cierra en poco más de un segundo, y el timeout
corto convertía una respuesta lenta en un fallo que encolaba el aviso sin
necesidad. El tope del producto sube de 5000 a 15000 ms porque, con la espera
tras fallo, un ciclo largo deja de repetirse cada segundo.

`CM_CHANNEL_MAX_LEN` y `CM_SNAPSHOT_SCHEMA` siguen siendo constantes: forman
parte del contrato compartido con el otro EA, no son preferencias.

## Mercado cerrado

Con dos brókers distintos los horarios de sesión no tienen por qué coincidir, y
el Master puede seguir publicando cambios mientras la sesión del Slave está
cerrada. Un rechazo por mercado cerrado no es un fallo de la copia: no hay nada
que decidir hasta que abra.

- Antes de cada corrección se consulta la sesión del símbolo con
  `SymbolInfoSessionTrade` para el día del servidor. Un símbolo sin sesiones
  declaradas se da por abierto y se delega en el retcode: bloquear por una
  heurística de cotizaciones dejaría sin corregir un instrumento poco líquido
  durante su propia sesión.
- Los retcodes `TRADE_RETCODE_MARKET_CLOSED`, `TRADE_RETCODE_TRADE_DISABLED` y
  `TRADE_RETCODE_PRICE_OFF` se clasifican como espera, no como fallo. Hace falta
  además del calendario porque un festivo no aparece en las sesiones.
- Mientras dura la espera se envía un único `BLOQUEADO`, el recordatorio
  `ALERTA` del problema se mantiene sin reenviar y el reintento se espacia a
  `InpMarketClosedRetrySeconds`. Sin esto, un fin de semana producía del orden
  de 30.000 órdenes rechazadas y 11.000 mensajes por problema, y la cola de
  Telegram acababa descartando avisos.
- Al abrir la sesión, la corrección sale adelante y se envía el `RESUELTO`
  normal. El panel muestra cuántos problemas están esperando apertura.

## Permisos y precios antes de corregir

- El permiso de trading del terminal, del EA y de la cuenta se comprueba una
  vez por ciclo. Sin él no se envía nada y el problema concreto se informa como
  `BLOQUEADO`, no como `CRÍTICO` repetido en cada ventana.
- Antes de crear o modificar se valida el modo de trading del símbolo, el
  rango de volumen del bróker y la distancia mínima del precio de entrada, SL y
  TP. Lo que el bróker rechazaría se informa como `BLOQUEADO` sin enviar nada.
- Un rechazo por modo de llenado se reintenta una sola vez con
  `ORDER_FILLING_RETURN`.
- La ausencia de permiso de trading no genera un aviso por sí sola: queda en el
  panel. Avisar sin discrepancias convertiría un monitor en modo sólo lectura en
  ruido permanente.
- **Escala de precios.** `PriceScaleSane` compara el precio que publica el
  Master con el precio actual del símbolo Slave y bloquea si el desvío pasa de
  `InpMaxPriceDeviationPercent` (50 % por defecto). No es una guarda de
  deslizamiento sino de equivalencia equivocada: un mapeo que apunta a otro
  instrumento produce diferencias de orden de magnitud, y la distancia mínima
  del bróker no lo detecta porque el valor puede ser perfectamente válido en el
  símbolo equivocado. Cubre crear, modificar y corregir SL/TP.
- **Distancia de congelación.** El MT5 no la comprobaba y el port MT4 sí, así
  que lo que el bróker iba a rechazar de todos modos salía como `CRÍTICO` en
  cada ventana en lugar de como `BLOQUEADO` con su motivo. `PendingNotFrozen` y
  `PositionNotFrozen` cierran la asimetría.
- **Cortacircuitos.** `InpMaxAutoActionsPerHour` acota las acciones automáticas
  por canal y por hora. Si la copiadora borra lo que el monitor crea, el
  ping-pong de órdenes se corta con un `BLOQUEADO` que nombra la sospecha. Se
  cuentan los intentos, no los aciertos: un ping-pong falla tanto como acierta.
  Un `BLOQUEADO` que no llegó a tocar la cuenta no gasta cupo.
- **Nivel de margen.** `InpMinMarginLevelPercent` (0 = desactivado) emite
  `MARGIN` cuando la cuenta Slave baja del umbral. Una copia que no entra por
  falta de margen se denunciaba como copia faltante sin nombrar la causa real.
