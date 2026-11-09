# Correcciones automáticas

El Slave sólo puede corregir automáticamente cuatro clases de problema:

1. SL o TP distintos en una posición activa: modifica exclusivamente SL/TP;
   nunca abre, cierra ni cambia volumen de posiciones.
2. Pendiente faltante: crea BUY/SELL LIMIT o BUY/SELL STOP con símbolo mapeado,
   volumen Slave normalizado, entrada, SL y TP. Las STOP LIMIT no se crean
   automáticamente porque el snapshot v1 no transporta su precio stop-limit.
3. Pendiente extra: mantiene la regla conservadora existente y sólo borra si el
   Master no tiene ninguna pendiente que pueda justificarla.
4. Precio, SL o TP distintos en una pendiente emparejada: modifica esos valores
   conservando tipo de tiempo, expiración y precio stop-limit del Slave.

Toda detección envía primero `ALERTA`. La acción se retrasa
`InpAutoFixPersistSeconds` —o `InpExtraPendingConfirmSeconds` para borrado— para
dar tiempo a Copyix a corregir. Al cumplirse el plazo se releen las colecciones,
se revalida ownership y se actúa sólo si el problema continúa.

Si Copyix resuelve durante la espera, se cancela el candidato y se envía
`RESUELTO`. Si CopyMonitor actúa, verifica el estado posterior y envía siempre
`RESUELTO` o `CRÍTICO`. Un fallo reinicia la ventana de persistencia para evitar
reintentos en cada ciclo. Los avisos de corrección no son opcionales: los
interruptores `InpNotifyDeleteSuccess` e `InpNotifyDeleteFailure` desaparecieron.

La creación sólo se intenta sobre un símbolo permitido por los filtros de la
instancia y disponible en el terminal, con tipo creable y volumen válido;
cualquier otro caso produce `BLOQUEADO` sin tocar la cuenta. Tras enviar la
orden se comprueba que la copia es visible como propia de ese canal. Si no lo
es, se avisa `CRÍTICO` y la creación automática de ese ticket Master queda
bloqueada hasta que el emparejamiento tenga éxito: reintentar duplicaría la
pendiente en cada ventana. La comparación de valores de una pendiente
emparejada depende de `InpMonitorPendingOrders`.

El estado interno —ventanas de persistencia, avisos cerrados y bloqueos de
creación— caduca tras una hora sin usarse, para que una sesión larga no acumule
claves de tickets antiguos.

Los controles son `InpAutoFixPositionSLTP`, `InpAutoCreateMissingPending`,
`InpAutoModifyPending`, `InpAutoDeleteExtraPending` e
`InpAutoFixPersistSeconds`. No ejecutar pruebas sobre cuentas reales sin orden
explícita del usuario.
