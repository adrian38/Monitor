# Mensajes de Telegram

Todos los avisos empiezan con el nivel de CopyMonitor, la hora de detección, el
alias de portafolio y la identificación de ambas cuentas. `DETECTADO` lleva la
hora local del terminal Slave en el momento de construir el aviso, no la del
envío: un aviso que esperó en la cola se entrega tarde y sin esa línea es
indistinguible de uno recién detectado. `PORTAFOLIO ALIAS` viene de
`InpPortfolioAlias`, `ID MASTER` y `BROKER MASTER` proceden del snapshot, y
`ID SLAVE` y `BROKER SLAVE` de `ACCOUNT_LOGIN` y `ACCOUNT_COMPANY` del
terminal Slave. `InpPortfolioAlias` es obligatorio: el EA no arranca sin él.
`InpSlaveID`, canal, owner, nick y perfil son datos internos y no se muestran
en Telegram.

Los avisos por operación contienen uno o más bloques `PROBLEMA` después de los
IDs y terminan con `ACCIÓN`.

En MT5, el aviso agregado `COUNT` muestra primero los motivos que lo activaron
y omite el detalle con valor cero. Después compara los recuentos visibles del
Slave con los del Master cuyos tickets y símbolos entran en la comparación.
Los tickets Master ignorados se indican aparte cuando los hay. Si los recuentos
coinciden, el mensaje lo indica y recuerda que el emparejamiento por operación
se comprueba por separado. Ver [protocol_and_safety.md](protocol_and_safety.md).

Cada operación indica `Estado` (`POSICIÓN ACTIVA` u `ORDEN PENDIENTE`), tipo en
texto, símbolo y tickets disponibles. Una diferencia de SL y TP se agrupa en el
mismo bloque de la posición; sólo se muestran los campos que difieren.

Una orden pendiente Master que falte en Slave incluye todo lo necesario para
revisarla o crearla manualmente: tipo, símbolos Master/Slave, ticket Master,
volumen Master, `Volumen Slave esperado` normalizado al paso del símbolo, precio
de entrada, SL y TP. La etiqueta dice **esperado** desde la v1.19 en los bloques
de copia faltante: ahí el valor es el que *debería* existir, y llamarlo
`Volumen Slave` como en los bloques que muestran el volumen real de una
operación del Slave hacía leer el aviso como si la copia existiera. Una STOP LIMIT añade `Precio límite`. El multiplicador se
usa internamente pero no se muestra. Los valores cero aparecen como `SIN SL` o
`SIN TP`.

En MT5, el aviso de copia pendiente faltante adapta el bloque `ACCIÓN` a
`InpAutoCreateMissingPending`. Si está desactivado, el texto indica que el
aviso es informativo y que la creación automática está desactivada.

Cuando varias copias son indistinguibles, el aviso explica que no existe una
identidad suficiente, pide revisión manual y confirma que no se enlaza ni se
corrige ninguna automáticamente. Ver [ambiguous_matching.md](ambiguous_matching.md).

Los niveles son:

- `🟠 COPYMONITOR — ALERTA`: intervención o revisión necesaria.
- `🟡 COPYMONITOR — BLOQUEADO`: se detectó una discrepancia pero no es seguro
  ejecutar una acción automática.
- `🔴 COPYMONITOR — CRÍTICO`: snapshot no disponible o acción fallida.
- `🟢 COPYMONITOR — RESUELTO`: el problema avisado ya no existe, lo haya
  corregido CopyMonitor o la propia copiadora.
- `🔵 COPYMONITOR — VIGILANCIA ACTIVA`: el aviso de arranque y el latido
  periódico del Slave. No es un problema: existe porque el EA que debería
  avisar de que ha muerto es precisamente el que ha muerto, así que sin un
  latido el silencio es ambiguo. Lleva el resumen por canal.

Los avisos que no hablan de un canal concreto —el terminal Slave desconectado,
el nivel de margen, los avisos perdidos, el latido— usan una cabecera propia
con `PORTAFOLIO ALIAS`, `ID SLAVE` y `BROKER SLAVE`. No hay cuenta Master que
identificar y no se inventa ninguna.

El vigilante MT4 (`terminal_watchdog.md`) comparte formato pero no tiene dos
cuentas que identificar: encabeza con `PORTAFOLIO ALIAS`, un `TERMINAL` opcional
y `ID TERMINAL`, `BROKER TERMINAL` y `SERVIDOR` de la cuenta vigilada. Usa
`🔴 CRÍTICO` para la caída, `🟢 RESUELTO` para la recuperación y
`🔵 COPYMONITOR — VIGILANCIA ACTIVA` para el aviso opcional de arranque, que
sólo sirve para comprobar que el terminal puede avisar.

Cada problema emite un `ALERTA` al detectarse y un único `RESUELTO` al cerrarse,
incluido el caso en que la operación avisada simplemente deja de existir. Una
corrección automática fallida emite `CRÍTICO` con retcode y detalle.

Esa garantía es por problema, no por canal: cada posición o pendiente avisada
tiene su propia clave de aviso, así que una copia que llega tarde se cierra con
su `RESUELTO` aunque otra operación del mismo canal siga mal. El precio es que
varios problemas simultáneos producen varios mensajes en lugar de uno agrupado.
También la recuperación del snapshot y la del esquema emiten `RESUELTO`. El
detalle de las claves está en [alert_lifecycle.md](alert_lifecycle.md).

## Entrega

El envío usa `POST`, así que el texto no depende del límite de longitud de una
URL. Un aviso de más de 3000 caracteres se trocea por líneas, porque Telegram
rechaza todo lo que pase de 4096 y el aviso completo se perdería. Todo aviso
entra en la cola y sale en `TgFlush`: publicar en línea ataba la duración del
ciclo al tiempo de respuesta de `api.telegram.org`, y con una tormenta de
avisos el monitor tardaba en detectar justo cuando más rápido había que
hacerlo. Lo que no logra salir espera en una cola acotada y se reintenta tras
la espera que fija el backoff, nunca en el ciclo siguiente; el panel muestra
cuántos avisos esperan, cuántos se descartaron por cola llena, los segundos que
faltan para el próximo intento y el último error.

Telegram no es el único camino. `InpEnablePushFallback` usa `SendNotification`,
que no depende de la whitelist de WebRequest, para un `CRÍTICO` que no va a
salir pronto, para cada descarte por cola llena y para el latido cuando
Telegram no está configurado. Y lo descartado deja rastro: `TGDROP` cuenta
cuántos avisos no llegaron, porque `AlertOnce`, `AlertOnChange` y los
`RESUELTO` se envían una sola vez y un descarte los borraba para siempre. `InpEnableTelegram` sin token o sin chat ID detiene
el arranque: dejaría al usuario sin ningún aviso y sin saberlo.

El detalle del backoff, del `retry_after` del `429` y de la persistencia del
estado de avisos está en [robustness.md](robustness.md). Lo que importa aquí: un
problema avisado antes de un reinicio conserva su `RESUELTO`, que hasta la v1.17
se perdía porque el estado vivía sólo en memoria.

