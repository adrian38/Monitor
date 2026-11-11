# Port MT4 de Master y Slave

`CopyMonitor_Master_MT4_v1_03_MULTI.mq4` y `CopyMonitor_Slave_MT4_v1_10_MULTI.mq4`
son la traducción a MQL4 del Master MT5 v1.17 y del Slave MT5 v1.30, con el
borrado por pareja de tickets de la v1.34 del Slave MT5. Conservan
el esquema de snapshot, el emparejamiento, los mensajes de Telegram y los
límites de automatización. Lo que cambia es la API del terminal, no el
contrato. Las decisiones de protocolo siguen en
[protocol_and_safety.md](protocol_and_safety.md) y las de robustez en
[robustness.md](robustness.md); aquí sólo está lo que es propio de MT4.

## Interoperabilidad

El snapshot es el mismo fichero, el mismo esquema `5` y los mismos códigos de
tipo, así que las cuatro combinaciones funcionan: Master MT4 con Slave MT5,
Master MT5 con Slave MT4 y los dos pares homogéneos. Eso es posible porque los
códigos de MT4 y MT5 coinciden en todo lo que el Master publica:

| Código | MT4            | MT5                     |
| ------ | -------------- | ----------------------- |
| 0      | `OP_BUY`       | `POSITION_TYPE_BUY`     |
| 1      | `OP_SELL`      | `POSITION_TYPE_SELL`    |
| 2      | `OP_BUYLIMIT`  | `ORDER_TYPE_BUY_LIMIT`  |
| 3      | `OP_SELLLIMIT` | `ORDER_TYPE_SELL_LIMIT` |
| 4      | `OP_BUYSTOP`   | `ORDER_TYPE_BUY_STOP`   |
| 5      | `OP_SELLSTOP`  | `ORDER_TYPE_SELL_STOP`  |

El snapshot no traduce nada: traducir obligaría a decidir en el lector de qué
plataforma viene el fichero, y el `META` no lo dice. Los códigos `6` y `7`
(STOP LIMIT) sólo existen en MT5.

Los tickets del snapshot viajan como `long` en las estructuras del Slave MT4,
porque un ticket de MT5 no cabe en el `int` de `OrderTicket()`. Se escriben con
`IntegerToString`, no con `StringFormat("%I64u")`, que MT4 no trata igual.

La pareja MT4 implementa también todo lo que el Slave MT5 añadió:
estado de conexión e identidad de sesión del Master, aviso obligatorio de la
ausencia sostenida, vigilancia del propio terminal, cuenta Master esperada,
avisos de volumen distinto, vínculo observado por pareja de tickets antes de
borrar,
cortacircuitos de acciones automáticas, guarda de escala de precios, nivel de
margen, latido, respaldo push, testigo de instancia y tolerancias por símbolo.
Lo único que no viaja al port es lo que MQL4 no expone.

## Lo que MT4 no tiene

- **Modo de margen de la cuenta.** No hay `ACCOUNT_MARGIN_MODE` y no hace
  falta: las cuentas MT4 son siempre de cobertura, así que la comprobación que
  el Slave MT5 hace en el arranque con `InpAllowNettingAccount` no tiene
  equivalente ni sentido aquí.

- **STOP LIMIT.** El Master MT4 publica siempre `0` en el campo stop-limit del
  registro `ORD`, y el Slave MT4 no puede crear una copia de los tipos `6` y
  `7`: la creación queda `BLOQUEADO` con el motivo concreto, igual que un
  Slave MT5 frente a un Master de esquema 1 o 2.
- **Colecciones separadas.** Posiciones y pendientes comparten la lista de
  operaciones, así que las dos colecciones se obtienen filtrando por tipo. El
  Master recorre la lista una sola vez: dos pasadas podrían mezclar dos fotos
  distintas del terminal.
- **`OnTradeTransaction`.** El disparo inmediato por cambio vive en `OnTick`.
  El Master compara el cuerpo (`POS` y `ORD`) que publicaría con el último
  publicado y sólo reescribe si cambió; el temporizador republica siempre para
  refrescar la marca de tiempo de la que depende la frescura. El Slave compara
  una firma de su lista de operaciones y recalcula esa firma al final de cada
  ciclo, para que lo que acaba de corregir no dispare otro ciclo.
- **`CTrade` y los retcodes.** Las correcciones se envían con `OrderSend`,
  `OrderModify` y `OrderDelete`, y el diagnóstico sale de `GetLastError`. Los
  equivalentes de `TRADE_RETCODE_MARKET_CLOSED`, `TRADE_DISABLED` y `PRICE_OFF`
  son los errores 132, 133 y 136. Un `OrderModify` que no cambia nada devuelve
  `false` con el error 1: es el `TRADE_RETCODE_NO_CHANGES` de MT5 y cuenta como
  éxito. No hay modo de llenado, así que desaparece el reintento con
  `ORDER_FILLING_RETURN`.
- **`ArrayRemove`.** No existe en MQL4, así que la lista de vínculos del canal
  cierra sus propios huecos con `RemovePendingLink`: desplaza a mano y reduce
  el tamaño. Lo demás del borrado por pareja de tickets es el mismo código que
  el Slave MT5, cuerpo por cuerpo, y una prueba lo comprueba.
- **`TimeTradeServer`.** Las sesiones se consultan contra `TimeCurrent()`, la
  hora del servidor en la última cotización.
- **Modos de trading del símbolo.** MT4 sólo expone si el símbolo admite
  operaciones (`MODE_TRADEALLOWED`). Los casos `LONGONLY`, `SHORTONLY` y
  `CLOSEONLY` de MT5 no se pueden anticipar: los rechaza el bróker y se
  informan con su código de error.

## Lo que MT4 añade

- **Historial en `OrderSelect`.** Seleccionar por ticket encuentra también
  operaciones cerradas, así que `SelectLiveOrder` exige `OrderCloseTime()==0`.
  Sin eso, un aviso sobre una pendiente ya borrada no se resolvería nunca y el
  `RESUELTO` no saldría. Una pendiente que se ejecuta cambia de tipo
  conservando el ticket, y eso también cierra su aviso.
- **Distancia de congelación.** Dentro de `MODE_FREEZELEVEL` el bróker rechaza
  modificar o borrar una pendiente aunque el precio sea válido. Se comprueba
  antes de enviar y se informa como `BLOQUEADO`, que es la misma regla que ya
  se aplicaba a la distancia mínima. El Slave MT5 no lo hacía y la v1.25 cierra
  esa asimetría con `SYMBOL_TRADE_FREEZE_LEVEL`.
- **Contexto de trading único.** Si otro EA lo tiene ocupado no hay nada que
  avisar: no se envía nada, el candidato sigue vivo y se reintenta en el ciclo
  siguiente. El panel lo muestra como `WAITING`.
- **Comentario de 31 caracteres.** Un comentario propietario más largo no
  podría coincidir con ninguna orden del terminal, así que detiene el arranque
  como cualquier otra configuración imposible. Un bróker que reescriba el
  comentario de la orden creada produce `CM_CREATE_UNVERIFIED`, que ya bloquea
  el reintento para no duplicar la pendiente.
- **Modificación de una posición.** `OrderModify` exige repetir el precio de
  apertura y una caducidad de cero. Al modificar una pendiente se conserva su
  caducidad: pasar cero convertiría en GTC una orden que tenía fecha.

## Verificación

`python -m tools.verify_project` comprueba los cuatro EAs. La regla
`ChannelIdValid` se compara entre los cuatro fuentes, no sólo dentro de cada
par: Master y Slave derivan el nombre del fichero común con la misma regla
independientemente de la plataforma.

Para compilar, el MetaEditor de MT4 acepta un fuente fuera del directorio de
datos y no hace falta `/inc` porque ninguno de los dos usa includes:

```
metaeditor.exe /compile:"<ruta>\CopyMonitor_Slave_MT4_v1_10_MULTI.mq4" /log:"<log>"
```

El código de salida no distingue el éxito: hay que leer la línea `Result:` del
log, que está en UTF-16.
