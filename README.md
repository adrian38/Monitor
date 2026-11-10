# CopyMonitor

Monitor de consistencia entre una cuenta Master y una cuenta Slave de
MetaTrader. El proyecto no copia operaciones: publica el estado del Master,
compara las copias existentes en el Slave y avisa de diferencias. Hay una
pareja Master/Slave para MetaTrader 5 y otra para MetaTrader 4, y un vigilante
independiente de MetaTrader 4 que avisa cuando un terminal pierde la conexión.

## Componentes

- `CopyMonitor_Master_MT5_v1_14_MULTI.mq5`: publica posiciones abiertas,
  órdenes pendientes y el bróker Master en el directorio común de MetaTrader.
- `CopyMonitor_Slave_MT5_v1_21_MULTI.mq5`: compara uno o varios canales,
  comprueba volumen, precio de entrada, SL/TP y pendientes, y puede eliminar
  únicamente pendientes extra confirmadas.
- `CopyMonitor_Master_MT4_v1_00_MULTI.mq4` y
  `CopyMonitor_Slave_MT4_v1_01_MULTI.mq4`: los mismos dos EAs para MetaTrader
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

El snapshot va por el esquema `3`: el `2` añadió el bróker del Master y el `3`
añade el precio stop-limit de las órdenes pendientes. **Master y Slave se
despliegan juntos**, porque un Slave anterior rechaza el esquema `3` y
suspendería la vigilancia. Al revés sí hay compatibilidad: un Master de esquema
`1` o `2` se sigue leyendo, el aviso muestra `BROKER MASTER: NO DISPONIBLE` y la
copia de una STOP LIMIT queda bloqueada por falta del precio límite. Un esquema
que el Slave no entiende se avisa siempre como `CRÍTICO`.

El identificador de canal admite de 1 a 32 caracteres de `A-Z a-z 0-9 _ - .`:
Master y Slave derivan de él el mismo nombre de fichero y un carácter fuera de
ese juego podía dejar al Slave leyendo un fichero que nadie escribe.

En modo single-master, configura `InpMasterChannel`, el multiplicador y, si es
necesario, el comentario propietario. En modo multi-master, las cuatro listas
`InpMasterChannels`, `InpOwnerComments`, `InpMasterProfiles` e
`InpVolumeMultipliers` son posicionales y deben tener la misma longitud.

Los temporizadores y límites internos están expuestos en el grupo
`TIMERS / LIMITES INTERNOS` del Slave y `TIMERS` del Master, con los valores que
el EA usaba fijos como valores por defecto. Si el mercado del símbolo está
cerrado —algo normal cuando los dos brokers no comparten horario— la corrección
queda en espera con un solo aviso y se aplica al abrir la sesión.

Cuando los brokers nombran un instrumento de forma diferente, usa
`InpSymbolMaps` con entradas `CANAL,SIMBOLO_MASTER,SIMBOLO_SLAVE` separadas por
punto y coma.

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

Para una entrega, compila además los dos EAs MQL5 con MetaEditor de MT5 y los
tres `.mq4` con el MetaEditor de MT4. Consulta `ai_context/main.md` para el
contrato técnico completo.

