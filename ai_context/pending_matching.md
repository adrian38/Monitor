# Matching de órdenes pendientes

El matching de pendientes es uno a uno. Cada orden Master monitorizada puede
proteger como máximo una orden Slave y cada orden Slave puede corresponder como
máximo a una Master. El emparejamiento exige canal/símbolo equivalente, tipo y
volumen esperado. El precio no forma parte de la identidad: una diferencia de
entrada genera una alerta y, tras persistir, una modificación. Lo mismo vale
para el precio límite de una STOP LIMIT, que sólo se compara cuando el Master lo
publica (esquema 3).

Los dos lados se recorren por ticket ascendente para que la evaluación sea
reproducible, pero el ticket no desempata. Antes de nada se intenta resolver la
ambigüedad por datos: cuando una pendiente Master admite dos o más copias libres
compatibles, sólo se ata una si es la única que coincide en todos los valores
comparados. Si varias candidatas siguen empatadas, se avisa, no se modifica
ninguna, no se crea otra copia y ninguna candidata se trata como extra borrable.
Ver [ambiguous_matching.md](ambiguous_matching.md).

Las pendientes asociadas a tickets Master ignorados se protegen después y se
retiran de todas las comprobaciones posteriores. Luego se emparejan las
pendientes Master no ignoradas con la copia compatible más cercana en precio.
`PMISS` cuenta Master no emparejadas; no compara únicamente tamaños de arrays.

Una Slave no emparejada sólo se considera huérfana borrable cuando el snapshot
Master no contiene ninguna pendiente. Si existe cualquier pendiente Master,
incluidas las ignoradas, se emite `PAMB` y se bloquea el borrado: una diferencia
de símbolo o configuración podría impedir el matching correcto. Cuando esa misma
pendiente pasa a estar emparejada, o el Master se queda sin pendientes, el
`PAMB` se cierra con `RESUELTO`.

## Activación temprana de la copia

Una copia que se ejecuta antes que su Master deja de ser pendiente en el Slave y
pasa a ser posición. El Master sigue publicando la pendiente, así que el Slave
la da por faltante. Sin más comprobación, `InpAutoCreateMissingPending` crearía
otra copia, esa copia podría volver a activarse antes, y la operación se
duplicaría sin fin.

Por eso, antes de crear, se mira si alguna posición activa del Slave que no
corresponde a ninguna posición Master podría ser esa pendiente ya ejecutada:
mismo símbolo equivalente, sentido compatible con el tipo de la pendiente y
volumen Slave esperado. El precio no entra en la comparación a propósito, porque
una activación llena a precio de mercado y exigir el precio de la pendiente
dejaría pasar justo el caso que hay que frenar. Si hay candidata se emite un
único `PEARLY` `BLOQUEADO`, no se crea nada, y el aviso de copia faltante se
mantiene vivo sin repetirse.

La regla es deliberadamente conservadora: si varias pendientes Master encajan
con la misma posición suelta, todas quedan bloqueadas. El coste de bloquear de
más es un aviso y una creación manual; el de bloquear de menos es duplicar la
operación. `CheckOpen` deja las posiciones no emparejadas en `g_unpaired_pos`
para que `CheckPending` las consulte; por eso el orden de las dos llamadas en
`ProcessOwner` importa. Ver [alert_lifecycle.md](alert_lifecycle.md).

## Borrado de una pendiente extra

Antes del borrado se espera `InpExtraPendingConfirmSeconds`, se vuelve a
seleccionar el ticket y se comprueban de nuevo tipo pendiente, filtro de símbolo
y ownership por comentario. Las posiciones abiertas nunca se cierran ni se
modifican desde este flujo: sólo se leen para reconocer una activación
temprana.
