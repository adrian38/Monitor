# CopyMonitor

Monitor de consistencia entre una cuenta Master y una cuenta Slave de
MetaTrader. El proyecto no copia operaciones: publica el estado del Master,
compara las copias existentes en el Slave y avisa de diferencias. Hay una
pareja Master/Slave para MetaTrader 5 y otra para MetaTrader 4, y un vigilante
independiente de MetaTrader 4 que avisa cuando un terminal pierde la conexión.

## Componentes

- `CopyMonitor_Master_MT5_v1_17_MULTI.mq5`: publica posiciones abiertas,
  órdenes pendientes y el bróker Master en el directorio común de MetaTrader.
- `CopyMonitor_Slave_MT5_v1_36_MULTI.mq5`: compara uno o varios canales,
  comprueba volumen, precio de entrada, SL/TP y pendientes, y puede eliminar
  únicamente pendientes extra confirmadas.
- `CopyMonitor_Master_MT4_v1_03_MULTI.mq4` y
  `CopyMonitor_Slave_MT4_v1_10_MULTI.mq4`: los mismos dos EAs para MetaTrader
  4, con el mismo esquema de snapshot y los mismos límites de automatización.
- `CopyMonitor_Watchdog_MT4_v1_00.mq4`: EA independiente para MetaTrader 4 que
  avisa por Telegram cuando el terminal pierde la conexión con su servidor y
  repite el aviso hasta que se recupera. No participa en el snapshot.

Los terminales se comunican mediante
`FILE_COMMON/CopyMonitorMulti/CM_<channel>.txt`. No requieren sockets ni un
servicio intermedio. MetaTrader 4 y MetaTrader 5 comparten ese directorio y
publican los mismos códigos de tipo, así que las cuatro combinaciones
funcionan: Master MT4 con Slave MT5, Master MT5 con Slave MT4 y los dos pares
homogéneos.

## MetaTrader 4

La pareja MT4 conserva el contrato de la MT5. Las diferencias que se notan al
usarla, con el detalle en [`ai_context/mt4_port.md`](ai_context/mt4_port.md):

- MT4 no tiene órdenes STOP LIMIT. Un Master MT4 nunca las publica y un Slave
  MT4 no puede crear la copia de una: queda `BLOQUEADO` con el motivo.
- El comentario propietario no puede pasar de 31 caracteres, que es el límite
  de MT4. Uno más largo detiene el arranque en lugar de dejar la vigilancia
  vacía en silencio.
- Hay un solo contexto de trading por terminal. Si otro EA lo tiene ocupado, la
  corrección espera al ciclo siguiente sin avisar; el panel lo muestra.
- Además de la distancia mínima, se respeta la distancia de congelación del
  bróker antes de modificar o borrar una pendiente.
- Los errores de trading son los de MT4 (132 mercado cerrado, 133 trading
  deshabilitado, 136 sin cotizaciones), y el aviso los muestra con su texto.

## Seguridad

- El Master nunca opera.
- El Slave nunca abre ni cierra posiciones.
- El Slave puede corregir SL/TP y crear, modificar o borrar pendientes dentro
  del alcance documentado. Toda corrección espera primero que el problema
  persista y vuelve a validar el estado.
- Ninguna corrección se intenta sin permiso de trading ni con precios o
  volúmenes que el bróker deba rechazar: esos casos se avisan como `BLOQUEADO`
  sin tocar la cuenta.
- Telegram es opcional. Los tokens y chat IDs se configuran en MT5 y no deben
  guardarse en el repositorio.

## Configuración esencial

`InpPortfolioAlias` es obligatorio en el Slave: encabeza cada aviso de Telegram
junto con los números y los brokers de ambas cuentas. El EA no arranca si está
vacío.

`InpEnableTelegram` exige token y chat ID: activarlo sin credenciales dejaría al
usuario sin ningún aviso y sin saberlo, así que el EA tampoco arranca.

El snapshot va por el esquema `5`: el `2` añadió el bróker del Master, el `3` el
precio stop-limit, el `4` el estado de conexión y el `5` una identidad nueva en
cada ejecución del Master. Esa identidad hace que un reinicio normal sea
detectable aunque la hora `written` siga avanzando. **Master y Slave se
despliegan juntos**, porque un Slave anterior rechaza el esquema `5` y
suspendería la vigilancia. El lector nuevo conserva los esquemas `1` a `4`
para monitorización, pero no ejecuta correcciones automáticas sin la identidad
de sesión del `5`. Un esquema desconocido se avisa siempre como `CRÍTICO`.

## Qué se vigila además de las operaciones

Un monitor que calla cuando se rompe no sirve de nada, así que el Slave avisa
también de lo que le impide vigilar:

- **El Master desconectado de su servidor.** Un terminal sin conexión sigue
  publicando la última foto conocida, que es fresca y falsa a la vez. La
  comparación y las correcciones se suspenden inmediatamente; tras
  `InpMasterOfflineConfirmSeconds` sale un `CRÍTICO`.
- **La falta de datos sostenida.** `InpNotifySnapshotProblems` gobierna sólo el
  corte transitorio; pasados `InpStaleAlertSeconds` el aviso es obligatorio.
- **El propio terminal Slave desconectado.** La automatización se suspende al
  primer ciclo sin enlace y el aviso espera `InpSlaveOfflineConfirmSeconds`.
- **Una cuenta Master distinta de la esperada**, si rellenas
  `InpExpectedMasterAccounts`.
- **Que el monitor sigue vivo.** `InpSendStartupNotice` confirma al arrancar
  que Telegram funciona, y `InpHeartbeatHours` repite un resumen cada N horas.
  Sin latido, no recibir nada significa «todo bien» sólo por costumbre.
- **Los avisos que no llegaron.** Si la cola se llena y descarta, sale un
  `CRÍTICO` que lo dice. `InpEnablePushFallback` añade además la notificación
  push de MetaQuotes, que no depende de la whitelist de WebRequest.
- **El nivel de margen de la cuenta Slave**, con `InpMinMarginLevelPercent`.

## Una copia con otro volumen no es una copia que falta

Un cierre parcial en el Master, un llenado parcial de la copia o un copiador
que dimensiona por riesgo dejan una copia viva con otro tamaño. Antes eso se
denunciaba como copia faltante y, en el caso de las pendientes, la creación
automática añadía una segunda orden junto a la que ya existía. Ahora se avisa
como volumen distinto, con los tres números —Master, Slave esperado y Slave
real— y sin tocar nada: CopyMonitor no cambia el volumen de una operación.

Por el mismo motivo, `InpAlertExtraPositions` está activo por defecto: «el
Master cerró y la copia sigue abierta» es el caso más caro de todos y ya no
depende del perfil.

## Límites de la automatización

- En MT5 el borrado requiere que el Slave haya observado una pareja inequívoca
  de tickets y que su pendiente Master lleve `InpEmptyMasterConfirmSeconds`
  ausente. Después se aplica `InpExtraPendingConfirmSeconds`. Una pendiente
  Master de otro símbolo no retrasa el borrado. En MT4 la primera confirmación
  sigue siendo por canal vacío.
- `InpMaxAutoActionsPerHour` corta el ping-pong si la copiadora deshace lo que
  el monitor hace.
- `InpMaxPriceDeviationPercent` bloquea cuando el precio del Master no encaja
  con la escala del símbolo Slave: casi siempre es una equivalencia mal puesta.
- La cuenta Slave debe ser de cobertura. En compensación el emparejamiento una
  copia por posición no es válido y el EA no arranca salvo que insistas con
  `InpAllowNettingAccount`.
- Dos instancias no pueden compartir `InpSlaveID`: un testigo atómico con token
  y latido evita que se pisen estado y avisos. El ID sólo admite letras,
  números, `_` y `-`.
- Si hay cualquier corrección automática activa, cada canal exige comentario
  propietario no vacío y cuenta Master esperada. Sin identidad inequívoca el
  Slave puede monitorizar, pero no actuar.
- Sólo puede haber un Master publicando un canal en la misma carpeta común. El
  segundo no arranca mientras el primero conserve su bloqueo de canal.

El identificador de canal admite de 1 a 32 caracteres de `A-Z a-z 0-9 _ - .`:
Master y Slave derivan de él el mismo nombre de fichero y un carácter fuera de
ese juego podía dejar al Slave leyendo un fichero que nadie escribe.

En modo single-master, configura `InpMasterChannel`, el multiplicador y, si es
necesario, el comentario propietario. En modo multi-master, las cuatro listas
`InpMasterChannels`, `InpOwnerComments`, `InpMasterProfiles` e
`InpVolumeMultipliers` son posicionales y deben tener la misma longitud.

`InpIgnoreSlaveComments` acepta comentarios exactos separados por coma o punto
y coma. Las posiciones y pendientes Slave con uno de esos comentarios quedan
fuera del ownership, del emparejamiento, de las correcciones y del aviso
agregado de cantidades; la comparación distingue mayúsculas y minúsculas.

Los temporizadores y límites internos están expuestos en el grupo
`TIMERS / LIMITES INTERNOS` del Slave y `TIMERS` del Master, con los valores que
el EA usaba fijos como valores por defecto. Si el mercado del símbolo está
cerrado —algo normal cuando los dos brokers no comparten horario— la corrección
queda en espera con un solo aviso y se aplica al abrir la sesión.

Cuando los brokers nombran un instrumento de forma diferente, usa
`InpSymbolMaps` con entradas `CANAL,SIMBOLO_MASTER,SIMBOLO_SLAVE` separadas por
punto y coma.

Las excepciones de `InpSymbolTolerances` pueden usar el nombre Master o el
nombre Slave declarado en ese mapeo. Si aparecen ambos, prevalece la entrada
del símbolo Slave. Dos nombres Master que apunten al mismo símbolo Slave no
pueden declarar tolerancias distintas sin una entrada explícita para el Slave.

## Vigilancia de terminal offline (MT4)

`CopyMonitor_Watchdog_MT4_v1_00.mq4` se adjunta a cualquier gráfico del
terminal MT4 que quieras vigilar y usa las mismas claves de Telegram que el
Slave: `InpTelegramBotToken` y `InpTelegramChatID` se rellenan en el terminal,
nunca en el repositorio. `InpPortfolioAlias` también es obligatorio aquí.

La caída se confirma tras `InpOfflineConfirmSeconds` segundos seguidos sin
conexión (60 por defecto), se avisa al confirmarla y el aviso se repite cada
`InpOfflineRepeatMinutes` minutos (5 por defecto) hasta que el terminal vuelve,
momento en el que sale un único `RESUELTO` con la duración de la caída. Un
recordatorio que no logra salir —porque lo caído es la línea de Internet— se
sustituye por el siguiente en lugar de acumularse.

`api.telegram.org` debe figurar en Herramientas → Opciones → Expert Advisors →
«Permitir WebRequest para las siguientes URL», o ningún aviso saldrá del
terminal.

El vigilante sólo puede informar mientras MT4 siga ejecutándose: si el terminal
se cierra o el equipo se apaga, no hay aviso. Detalles en
`ai_context/terminal_watchdog.md`.

## Verificación

La comprobación estática del repositorio no abre MetaTrader:

```powershell
python -m tools.verify_project
```

Las pruebas unitarias de los ayudantes Python y de las reglas de borrado de
pendientes MT5 tampoco abren MetaTrader:

```powershell
python -m unittest discover -s tools -p "test_*.py"
```

Para una entrega, compila además los dos EAs MQL5 con MetaEditor de MT5 y los
tres `.mq4` con el MetaEditor de MT4. Consulta `ai_context/main.md` para el
contrato técnico completo.

Las compilaciones históricas se conservan separadas por plataforma en
`compiled/MT5` (`.ex5`) y `compiled/MT4` (`.ex4`). Junto a las fuentes quedan
únicamente los cuatro binarios de la versión vigente: Master y Slave de MT4 y
MT5.

