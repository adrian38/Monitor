# Ciclo de vida de un aviso

Cada problema que el Slave detecta vive en `g_alerts` bajo una **clave**. La
clave decide tres cosas: cuándo se repite el recordatorio, cuándo se resuelve y
qué sobrevive a un reinicio. Las funciones son:

- `PersistAlert(clave,msg)`: marca el problema activo y envía `ALERTA` la
  primera vez y luego cada `InpMismatchReminderSeconds`.
- `KeepAlert(clave)`: mantiene vivo un aviso ya emitido sin reenviarlo.
- `AlertOnce(clave,msg)`: un único envío mientras el problema dure, para las
  esperas de mercado cerrado.
- `AlertOnChange(clave,firma,msg)`: como `AlertOnce`, pero reenvía cuando la
  firma del contenido cambia. Para un aviso que no debe repetirse cada ciclo y
  cuyo panorama sí puede moverse. La firma vive en memoria, no en disco: tras
  un reinicio el primer ciclo vuelve a contar la situación actual.
- `ResolveAlert(clave,msg)`: envía `RESUELTO` **sólo si la clave estaba
  activa** y la apaga. Es la única forma correcta de cerrar un problema que el
  usuario ya conoce.
- `ClearAlert(clave)` y `ClearAlertsWithPrefix(prefijo)`: apagan sin enviar
  nada. Reservados para los casos en que ningún `RESUELTO` sería cierto: el
  mensaje de la corrección automática ya lo dijo, el usuario dejó de vigilar
  ese ticket, o la clave pertenece a una versión anterior.

## Una clave por problema

Hasta la v1.20 los problemas de posiciones compartían una única clave
`OPEN|<canal>` y las pendientes faltantes una única `PMISS|<canal>`. Un aviso
agrupado sólo puede resolverse cuando **todos** sus problemas desaparecen a la
vez, y el cierre se hacía además con `ClearAlert`, así que el caso normal —el
Master abre antes que el Slave y la copia llega unos segundos después— emitía
`ALERTA` y no emitía nunca `RESUELTO`.

Desde la v1.21 del Slave MT5 y la v1.01 del Slave MT4 cada problema tiene su
propia clave, con su propio `ALERTA` y su propio `RESUELTO`:

| Clave | Problema | Se resuelve cuando |
| --- | --- | --- |
| `POSMISS\|canal\|ticketMaster` | Falta la copia de una posición activa | aparece la copia, o la posición Master deja de existir |
| `POSAMB\|canal\|ticketMaster` | Enlace ambiguo de una posición | queda una única copia compatible, o la posición Master deja de existir |
| `POSEXTRA\|canal\|ticketSlave` | Posición activa extra en el Slave | deja de sobrar, o la posición Slave deja de existir |
| `POSVOL\|canal\|master\|slave` | La copia de una posición existe con otro volumen | los volúmenes vuelven a coincidir, o desaparece cualquiera de los dos lados |
| `PVOL\|canal\|master\|slave` | La copia de una pendiente existe con otro volumen | igual que `POSVOL` |
| `ORDMISS\|canal\|ticketMaster` | Falta la copia de una pendiente | aparece la copia, se crea automáticamente, o la pendiente Master deja de existir |
| `PEARLY\|canal\|ticketMaster` | La copia se activó antes que su Master | deja de haber una posición Slave suelta que encaje, o la pendiente Master deja de existir |
| `SLTP\|canal\|master\|slave` | SL o TP distintos en una posición | coinciden, o el ticket Slave deja de existir |
| `PVALUES\|canal\|master\|slave` | Valores distintos en una pendiente | coinciden, o el ticket Slave deja de existir |
| `PEXTRA\|canal\|ticketSlave` | Pendiente extra en el Slave | se empareja o deja de existir |
| `PAMB\|canal\|ticketSlave` | Pendiente Slave sin Master emparejable | se empareja o deja de existir |
| `PAMBMASTER\|canal\|ticketMaster` | Enlace ambiguo de una pendiente | queda una única copia compatible |
| `SCHEMA\|canal` | Esquema o canal del snapshot incompatibles | el snapshot vuelve a ser legible |
| `STALE\|canal` | Snapshot ausente o caducado | vuelven los datos recientes |
| `COUNT\|canal` | Las cantidades no cuadran por algo sin aviso propio | todo vuelve a explicarse |
| `MOFF\|canal` | El terminal Master perdió la conexión con su servidor | la recupera |
| `MACCOUNT\|canal` | El snapshot lo publica otra cuenta Master | vuelve la cuenta esperada |
| `SOFF\|InpSlaveID` | El terminal Slave perdió la conexión | la recupera |
| `MARGIN\|InpSlaveID` | Nivel de margen por debajo del mínimo | vuelve a subir |
| `TGDROP\|InpSlaveID` | La cola de Telegram descartó avisos | la cola vuelve a vaciarse |

Las cuatro últimas no pertenecen a ningún canal: usan `LocalHeader`, que
encabeza con el alias del portafolio y la cuenta Slave y no inventa una cuenta
Master que no hay. `MOFF`, `MACCOUNT`, `SOFF` y `STALE` suspenden además la
comparación y toda corrección automática mientras duran, porque los datos que
habría que comparar son una foto del pasado.

`FAIL|<clave>` y `PBLOCK|<clave>` acompañan a la clave del problema cuando una
corrección falla o queda bloqueada, y se cierran con ella.

Los avisos de espera usan `AlertOnce` y `COUNT|canal` usa `AlertOnChange`:
ninguno repite recordatorio por ciclo, que sería ruido, pero el del descuadre
se reenvía cuando sus cifras cambian, porque un descuadre distinto no es el
mismo aviso. Los números vivos están siempre en el panel.

La consecuencia práctica es que un portafolio con varios problemas simultáneos
recibe varios mensajes en lugar de uno agrupado. Es el mismo comportamiento que
ya tenían los avisos de SL/TP, y el precio de poder cerrar cada problema por
separado. La cola de Telegram está acotada por `InpTelegramQueueMax`.

## Avisos sobre tickets que ya no existen

`ResolveVanishedAlerts` recorre las claves activas al final de cada ciclo y
cierra las que se refieren a un ticket que ya no aparece ni en el snapshot
Master ni en la cuenta Slave. Sin eso, un aviso sobre una posición que el Master
cerró antes de que el Slave la copiara quedaría activo para siempre: nunca
volvería a visitarse y los avisos activos no caducan por `InpStateTTLSeconds`.

Toda familia de claves nueva debe añadirse a esa función, o su aviso no podrá
cerrarse nunca.

## Claves retiradas

`OPEN|<canal>` y `PMISS|<canal>` ya no se usan. Ambos Slave llaman a
`ClearAlert` sobre ellas en cada ciclo para que un fichero de estado escrito por
una versión anterior no conserve un aviso activo e inmortal. Ver
[robustness.md](robustness.md) para la persistencia del estado y
[telegram_messages.md](telegram_messages.md) para el formato de los mensajes.
