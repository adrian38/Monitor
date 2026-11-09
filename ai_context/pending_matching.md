# Matching de órdenes pendientes

El matching de pendientes es uno a uno. Cada orden Master monitorizada puede
proteger como máximo una orden Slave y cada orden Slave puede corresponder como
máximo a una Master. El emparejamiento exige canal/símbolo equivalente, tipo y
volumen esperado. El precio no forma parte de la identidad: una diferencia de
entrada genera una alerta y, tras persistir, una modificación. Lo mismo vale
para el precio límite de una STOP LIMIT, que sólo se compara cuando el Master lo
publica (esquema 3).

Las pendientes asociadas a tickets Master ignorados se protegen primero y se
retiran de todas las comprobaciones posteriores. Después se emparejan las
pendientes Master no ignoradas con la copia compatible más cercana en precio.
`PMISS` cuenta Master no emparejadas; no compara únicamente tamaños de arrays.

Una Slave no emparejada sólo se considera huérfana borrable cuando el snapshot
Master no contiene ninguna pendiente. Si existe cualquier pendiente Master,
incluidas las ignoradas, se emite `PAMB` y se bloquea el borrado: una diferencia
de símbolo o configuración podría impedir el matching correcto. Cuando esa misma
pendiente pasa a estar emparejada, o el Master se queda sin pendientes, el
`PAMB` se cierra con `RESUELTO`.

Antes del borrado se espera `InpExtraPendingConfirmSeconds`, se vuelve a
seleccionar el ticket y se comprueban de nuevo tipo pendiente, filtro de símbolo
y ownership por comentario. Las posiciones abiertas nunca entran en este flujo.
