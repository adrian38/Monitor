# Correcciones automáticas

El Slave sólo puede corregir automáticamente cuatro clases de problema:

1. SL o TP distintos en una posición activa: modifica exclusivamente SL/TP;
   nunca abre, cierra ni cambia volumen de posiciones.
2. Pendiente faltante: crea la copia con símbolo mapeado, volumen Slave
   normalizado, entrada, SL y TP. Nunca cuando la copia parece haberse activado
   antes que el Master: ver [pending_matching.md](pending_matching.md). Desde el esquema 3 el snapshot transporta el
   precio stop-limit, así que también se pueden crear BUY/SELL STOP LIMIT; con
   un Master de esquema 1 o 2 ese precio no llega y la creación queda
   `BLOQUEADO`.
3. Pendiente extra: mantiene la regla conservadora existente y sólo borra si el
   Master no tiene ninguna pendiente que pueda justificarla.
4. Precio, precio límite, SL o TP distintos en una pendiente emparejada:
   modifica esos valores conservando tipo de tiempo y expiración de la copia.

Toda detección envía primero `ALERTA`. La acción se retrasa para dar tiempo a
Copyix a corregir: `InpMissingPendingConfirmSeconds` para crear una pendiente
que falta, `InpExtraPendingConfirmSeconds` para borrar una extra y
`InpAutoFixPersistSeconds` para las correcciones de valores. Crear una orden
nueva no es lo mismo que ajustar lo que ya existe, así que la creación tiene su
propio retardo desde la v1.22. Al cumplirse el plazo se releen las colecciones,
se revalida ownership y se actúa sólo si el problema continúa.

Si Copyix resuelve durante la espera, se cancela el candidato y se envía
`RESUELTO`. Si CopyMonitor actúa, verifica el estado posterior y envía siempre
`RESUELTO` o `CRÍTICO`. Un fallo reinicia la ventana de persistencia para evitar
reintentos en cada ciclo. Los avisos de corrección no son opcionales: los
interruptores `InpNotifyDeleteSuccess` e `InpNotifyDeleteFailure` desaparecieron.

Ninguna de las cuatro se intenta mientras el Master esté desconectado de su
servidor, el snapshot lleve sin llegar más de la cuenta, la cuenta Master no
sea la esperada o el propio terminal Slave haya perdido la conexión. En esos
cuatro casos los datos que habría que comparar son una foto del pasado, y
corregir contra el pasado es peor que no corregir. Ver
[robustness.md](robustness.md).

Una copia que existe con **otro volumen** tampoco se corrige: se avisa como
`POSVOL` o `PVOL` y se deja en manos del usuario. El Slave no cambia nunca el
volumen de una posición, y ajustar el precio de una pendiente cuyo tamaño ya no
es el pedido afianzaría una copia equivocada. Lo importante es que esa copia
cuenta como emparejada: antes contaba como ausente y la creación automática
añadía una segunda orden junto a la que ya existía. Ver
[pending_matching.md](pending_matching.md).

## Comprobaciones previas

Antes de enviar nada se exige, en este orden:

- permiso de trading del terminal, del EA en el gráfico y de la cuenta;
- símbolo permitido por los filtros de la instancia y disponible en el terminal;
- modo de trading del símbolo compatible con el sentido de la orden;
- volumen dentro del rango del bróker antes de cualquier recorte: crear fuera
  de rango significaría copiar un tamaño distinto del pedido por el Master;
- escala de precios coherente con el símbolo Slave: un desvío mayor que
  `InpMaxPriceDeviationPercent` entre el precio del Master y el precio actual
  delata una equivalencia que apunta a otro instrumento;
- distancia mínima del bróker para el precio de entrada y para SL y TP, con
  precios actuales disponibles;
- distancia de congelación del bróker antes de modificar o borrar;
- cupo de acciones automáticas de la hora para ese canal.

Si el mercado del símbolo está cerrado, el problema entra en espera: un único
`BLOQUEADO`, sin repetir el recordatorio del problema, con reintento cada
`InpMarketClosedRetrySeconds` y corrección en cuanto abra la sesión. Lo mismo
vale cuando el bróker rechaza con mercado cerrado, trading deshabilitado o falta
de cotizaciones, que es lo que cubre un festivo no declarado en las sesiones.
Ver [robustness.md](robustness.md).

Cualquier otra comprobación fallida produce `BLOQUEADO` con el motivo concreto y
no toca la cuenta. Esto sustituye al `CRÍTICO` repetido en cada ventana que
generaba antes una orden estructuralmente imposible. Un rechazo por modo de
llenado se reintenta una sola vez con `ORDER_FILLING_RETURN`.

Tras enviar la orden se comprueba que la copia es visible como propia de ese
canal **y** que resulta emparejable con la orden Master. Si no lo es, se avisa
`CRÍTICO` y la creación automática de ese ticket Master queda bloqueada hasta
que el emparejamiento tenga éxito: reintentar duplicaría la pendiente en cada
ventana. La comparación de valores de una pendiente emparejada depende de
`InpMonitorPendingOrders`.

El estado interno —ventanas de persistencia, avisos cerrados y bloqueos de
creación— caduca tras una hora sin usarse, para que una sesión larga no acumule
claves de tickets antiguos. Un aviso cuyo ticket ya no existe se cierra con
`RESUELTO` en lugar de quedarse activo para siempre.

Los controles son `InpMissingPendingConfirmSeconds` para el retardo de creación,
`InpAutoFixPositionSLTP` para SL/TP de posiciones activas,
`InpAutoFixPendingSLTP` para SL/TP de pendientes, `InpAutoModifyPending` para
precio de entrada y precio límite de pendientes, `InpAutoCreateMissingPending`,
`InpAutoDeleteExtraPending` e `InpAutoFixPersistSeconds`. Al modificar una
pendiente se conservan los campos cuyo interruptor esté desactivado. No ejecutar
pruebas sobre cuentas reales sin orden explícita del usuario.
