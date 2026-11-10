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

Después de los IDs, el mensaje contiene uno o más bloques `PROBLEMA` y termina
con `ACCIÓN`. No se incluye un resumen de contadores que obligue al usuario a
buscar después los datos operativos.

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

Un bloque de diferencia puede terminar con un `AVISO`: la pareja Master/Slave
que se informa se fijó por el orden de apertura porque hay otra operación
idéntica en la cuenta y ningún valor comparado las distingue. El
emparejamiento es estable y reproducible, pero no es una identidad, así que el
aviso pide revisarlo a mano. Ver
[ambiguous_matching.md](ambiguous_matching.md).

Los niveles son:

- `🟠 COPYMONITOR — ALERTA`: intervención o revisión necesaria.
- `🟡 COPYMONITOR — BLOQUEADO`: se detectó una discrepancia pero no es seguro
  ejecutar una acción automática.
- `🔴 COPYMONITOR — CRÍTICO`: snapshot no disponible o acción fallida.
- `🟢 COPYMONITOR — RESUELTO`: el problema avisado ya no existe, lo haya
  corregido CopyMonitor o la propia copiadora.

El vigilante MT4 (`terminal_watchdog.md`) comparte formato pero no tiene dos
cuentas que identificar: encabeza con `PORTAFOLIO ALIAS`, un `TERMINAL` opcional
y `ID TERMINAL`, `BROKER TERMINAL` y `SERVIDOR` de la cuenta vigilada. Usa
`🔴 CRÍTICO` para la caída, `🟢 RESUELTO` para la recuperación y
`🔵 COPYMONITOR — VIGILANCIA ACTIVA` para el aviso opcional de arranque, que
sólo sirve para comprobar que el terminal puede avisar.

Cada problema emite un `ALERTA` al detectarse y un único `RESUELTO` al cerrarse,
incluido el caso en que la operación avisada simplemente deja de existir. Una
corrección automática fallida emite `CRÍTICO` con retcode y detalle.

## Entrega

El envío usa `POST`, así que el texto no depende del límite de longitud de una
URL. Un aviso de más de 3000 caracteres se trocea por líneas, porque Telegram
rechaza todo lo que pase de 4096 y el aviso completo se perdería. Lo que no
logra salir espera en una cola acotada y se reintenta tras la espera que fija el
backoff, nunca en el ciclo siguiente; el panel muestra cuántos avisos esperan,
cuántos se descartaron por cola llena, los segundos que faltan para el próximo
intento y el último error. `InpEnableTelegram` sin token o sin chat ID detiene
el arranque: dejaría al usuario sin ningún aviso y sin saberlo.

El detalle del backoff, del `retry_after` del `429` y de la persistencia del
estado de avisos está en [robustness.md](robustness.md). Lo que importa aquí: un
problema avisado antes de un reinicio conserva su `RESUELTO`, que hasta la v1.17
se perdía porque el estado vivía sólo en memoria.

