# Vigilancia de terminal offline (MT4)

## Por qué no hay un vigilante MT5

Desde la v1.25 del Slave MT5 y la v1.05 del MT4 no hace falta un EA aparte para
esto, y por eso no se escribió:

- el Master publica su estado de conexión en el `META` (esquema 4), así que el
  Slave avisa con `MOFF` cuando el terminal Master pierde el enlace;
- el Slave vigila su propia conexión y avisa con `SOFF`;
- el latido (`InpHeartbeatHours`) y el aviso de arranque cubren el caso que un
  vigilante de conexión nunca podría cubrir: que el EA se haya descargado, que
  AutoTrading esté apagado o que el terminal se haya cerrado.

El vigilante MT4 sigue teniendo sentido para un terminal que no participa en
ningún canal y al que sólo se quiere mirar la conexión.

`CopyMonitor_Watchdog_MT4_v1_00.mq4` es un EA independiente para MetaTrader 4.
No lee ni escribe el snapshot compartido, no conoce canales ni perfiles y nunca
opera la cuenta: sólo observa la conexión del terminal y avisa por Telegram.

## Qué considera offline

El estado lo decide `IsConnected()`: el terminal perdió la conexión con su
servidor de trading. Un mercado cerrado no es una caída, porque el terminal
sigue conectado. Una microdesconexión tampoco: la caída se da por confirmada
sólo después de `InpOfflineConfirmSeconds` segundos seguidos sin conexión. El
campo `Sin conexión desde` del mensaje apunta a la primera comprobación fallida,
no al momento en que la caída se dio por confirmada.

Mientras la caída sigue, se repite un aviso cada `InpOfflineRepeatMinutes`
minutos (5 por defecto). Al recuperarse la conexión sale un único `RESUELTO`
con la duración de la caída y cuántos avisos se enviaron.

## Por qué OnTimer y no OnTick

Sin conexión no llegan ticks, así que `OnTick` deja de ejecutarse justo cuando
hay que avisar. Todo el ciclo vive en `OnTimer`, creado con `EventSetTimer`.
Por la misma razón los instantes se toman de `TimeLocal()`: `TimeCurrent()` se
queda congelado en la última cotización recibida y mediría mal la caída.

El reloj local puede retroceder (cambio de hora, sincronización NTP). Cada
ciclo recorta las marcas de tiempo que queden en el futuro, para que un salto
atrás no congele los recordatorios ni produzca duraciones negativas.

## Entrega de los avisos

El envío es el mismo `POST` a `api.telegram.org` que usa el Slave, con los
mismos parámetros de token, chat ID, timeout, troceo y cola. La diferencia es
la colapsación por clave: si una caída de Internet impide enviar, el
recordatorio `OFFLINE` pendiente se sustituye por el siguiente en lugar de
acumularse, así que al volver la línea el usuario recibe el estado vigente y no
una avalancha de copias viejas. La colapsación sólo se aplica cuando el aviso
cabe en un envío; un mensaje troceado se encola entero.

`InpSendStartupNotice` manda un aviso de arranque. Es la forma de comprobar que
el token, el chat ID y la lista de URLs permitidas de MT4 están bien puestos sin
esperar a una caída real. Ese envío ocurre en el primer `OnTimer`, no en
`OnInit`: una llamada de red en `OnInit` bloquearía la carga del terminal.

## Límite conocido

Un vigilante que vive dentro del terminal no puede avisar de su propia muerte.
Si MT4 se cierra, el equipo se apaga o pierde la corriente, no sale ningún
aviso. Esto cubre la desconexión del terminal con el servidor, no la caída de
la máquina; para eso haría falta un vigilante externo que espere latidos.

## Configuración en MT4

`api.telegram.org` debe estar en Herramientas → Opciones → Expert Advisors →
«Permitir WebRequest para las siguientes URL». Sin eso `WebRequest` devuelve
error 4060 y el panel lo muestra en `Último error`.
