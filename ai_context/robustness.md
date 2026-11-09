# Robustez operativa

Decisiones tomadas para que un fallo del entorno no deje al monitor mudo ni le
haga actuar a ciegas. Son contrato: no se deben revertir sin sustituirlas.

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
- Se distingue el tipo de problema: ausencia o lectura parcial es transitoria y
  la gobierna `InpNotifySnapshotProblems`; un esquema desconocido o un canal
  cruzado son contrato roto y se avisan **siempre** como `CRÍTICO`. Un Master
  más nuevo que el Slave no puede dejar la vigilancia parada en silencio.
- Se admite un segundo de adelanto del reloj al calcular la frescura.

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

Dos cambios pueden rechazar una configuración que antes arrancaba:

- un `InpMasterChannel` o un `InpMasterChannels` con espacios u otros
  caracteres fuera del juego permitido;
- `InpEnableTelegram` activado sin token o sin chat ID.

`InpVolumeToleranceSteps` se respeta tal cual: antes un cero se trataba como
uno, lo que contradecía la documentación. Con cero la comparación de volumen es
exacta salvo el ruido de coma flotante.

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
  instancia y dos Slave distintos no deben pisarse el fichero.
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
