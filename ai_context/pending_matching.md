# Matching de órdenes pendientes

El matching de pendientes es uno a uno. Cada orden Master monitorizada puede
proteger como máximo una orden Slave y cada orden Slave puede corresponder como
máximo a una Master. El emparejamiento exige canal/símbolo equivalente, tipo y
volumen esperado. El precio no forma parte de la identidad: una diferencia de
entrada genera una alerta y, tras persistir, una modificación. Lo mismo vale
para el precio límite de una STOP LIMIT, que sólo se compara cuando el Master lo
publica (esquema 3).

Los dos lados se recorren por ticket ascendente para que la evaluación sea
reproducible, pero el ticket no desempata. La unicidad se comprueba en los dos
sentidos: una copia tampoco se asigna si puede corresponder a dos Master libres.
Antes de nada se intenta resolver la ambigüedad por datos: cuando una pendiente
Master admite dos o más copias libres compatibles, sólo se ata una si es la
única que coincide en todos los valores comparados. Si varias candidatas siguen
empatadas, o una candidata no identifica una sola Master, se avisa, no se
modifica ninguna, no se crea otra copia y ninguna candidata se trata como extra borrable.
Ver [ambiguous_matching.md](ambiguous_matching.md).

## La copia con otro volumen

`OrdCompatible` exige `VolEq`. Una copia con otro tamaño —llenado parcial,
redondeo distinto del copiador, mínimo del bróker receptor, o un copiador que
dimensiona por riesgo en vez de por multiplicador fijo— dejaba de ser
compatible, la orden Master contaba como no emparejada y
`InpAutoCreateMissingPending` añadía una **segunda** pendiente mientras la
primera seguía viva: dos órdenes donde debía haber una, creadas por el propio
monitor. La primera tampoco se borraba, porque el Master sí tenía pendientes.

Antes de dar una orden Master por no emparejada se busca una copia libre
compatible **ignorando el volumen**. Si hay exactamente una:

- se marca la Master como emparejada, así que no se crea otra copia;
- se protege la Slave, así que tampoco sobra;
- se emite `PVOL` con los tres volúmenes (Master, Slave esperado, Slave real);
- **no** se corrigen sus valores: ajustar el precio de una orden cuyo tamaño ya
  no es el pedido afianzaría una copia equivocada.

Dos candidatas igual de buenas, o una misma candidata válida para varias Master,
siguen sin aportar identidad y no se ata ninguna, como en el resto del
emparejamiento.

Las pendientes asociadas a tickets Master ignorados se protegen después y se
retiran de todas las comprobaciones posteriores. Luego se emparejan las
pendientes Master no ignoradas con la copia compatible más cercana en precio.
`PMISS` cuenta Master no emparejadas; no compara únicamente tamaños de arrays.

En MT4, una Slave no emparejada sólo se considera huérfana borrable cuando el snapshot
Master no contiene ninguna pendiente **y lleva así
`InpEmptyMasterConfirmSeconds` seguidos**. La condición «el Master no tiene
pendientes» la cumple también un Master recién reconfigurado —otro filtro de
símbolos, otro comentario, otra cuenta con el mismo canal—, que publica un
snapshot válido y fresco con cero pendientes; con la confirmación de dos
segundos que había antes, el Slave borraba pendientes reales sin que nadie
pudiera intervenir. El esquema 5 publica una identidad de sesión distinta en
cada arranque; cualquier cambio reinicia esa cuenta atrás. La marca `written`
sólo queda como compatibilidad de lectura para esquemas antiguos, que no pueden
autorizar acciones automáticas. Si existe cualquier pendiente Master,
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
operación. Por eso mismo la búsqueda se hace en dos pasadas: primero exigiendo
el volumen esperado y, si no hay candidata, sin exigirlo. Una activación que se
llena parcialmente seguía siendo esa pendiente ya ejecutada, y con el volumen
como requisito se colaba justo el caso que hay que frenar. El aviso dice cuál
de las dos pasadas encontró la candidata. `CheckOpen` deja las posiciones no emparejadas en `g_unpaired_pos`
para que `CheckPending` las consulte; por eso el orden de las dos llamadas en
`ProcessOwner` importa. Ver [alert_lifecycle.md](alert_lifecycle.md).

## Borrado por pareja de tickets

El Slave recuerda en memoria las parejas identificadas con el volumen
esperado. Si hay otras candidatas del mismo símbolo equivalente
y tipo, los valores comparados deben distinguir la pareja en ambos sentidos.
Para detectar ambigüedad se tienen en cuenta todas las candidatas, aunque
tengan otro volumen o ya estén asignadas por el matching. Un ticket Master
ignorado no puede autorizar un borrado. Si la pareja se vuelve ambigua o el
Slave queda protegido por otro emparejamiento, se descarta el vínculo.

Cuando desaparece el ticket Master, se confirma su ausencia durante
`InpEmptyMasterConfirmSeconds` y después se exige que la copia siga sobrando
durante `InpExtraPendingConfirmSeconds`. Una pendiente de AUDCAD no bloquea
una baja de XAUUSD. Una pendiente Master del mismo símbolo equivalente y tipo
bloquea el borrado salvo que tenga su propia copia viva identificada
inequívocamente. Este criterio también se comprueba con las órdenes Slave
actuales justo antes de enviar la cancelación.
Sin vínculo previo se emite `PAMB`. Por eso una copia que ya estaba huérfana
al instalar la versión necesita revisión manual. Una pérdida de confianza o un
reinicio descarta los vínculos y los contadores.

De la v1.31 a la v1.33 la unicidad se decidía sólo por símbolo equivalente y
tipo: cualquier otra candidata de cualquiera de los dos lados descartaba la
pareja aunque los precios la distinguieran. Con dos copias del mismo símbolo y
tipo no quedaba ningún vínculo, así que la ausencia del ticket Master no se
confirmaba nunca y el único mensaje posible era `PAMB`. El caso de AUDUSD del
11-11-2026 lo muestra: dos `sell limit` de 0.01 a 0.69256 y 0.68962, separadas
294 puntos frente a los 100 de `InpPendingPriceTolerancePoints`.

El criterio sigue siendo conservador a propósito. Una pendiente Master
alternativa cuya copia ya se activó y es posición no tiene copia pendiente
viva, así que bloquea el borrado y la copia sobrante sólo se avisa. Borrar es
la única acción destructiva del EA: bloquear de más cuesta un aviso y una
revisión manual, borrar de menos cuesta una copia legítima.

La regla es de las dos plataformas. El Slave MT5 la estrenó en la v1.31 y la
corrigió en la v1.34; el port MT4 la adoptó en su v1.10, donde sustituye a una
puerta mucho más tosca: hasta la v1.09 sólo borraba una pendiente huérfana
cuando el snapshot Master no tenía ninguna pendiente, de modo que un Master con
otra pendiente cualquiera —de otro símbolo incluso— bloqueaba el borrado para
siempre.

`tools/test_pending_delete_rules.py` transcribe estas dos reglas y las ejecuta
contra ese caso real, contra pendientes gemelas indistinguibles y contra la
regla anterior, y comprueba que el cuerpo de las funciones es el mismo en los
dos EAs.

Justo antes del borrado se vuelve a seleccionar el ticket Slave y se
comprueban tipo pendiente, filtro de símbolo y ownership por comentario.
Después se relee el snapshot para confirmar esquema 5, cuenta, sesión, enlace,
ventana de recuperación y ausencia de la pendiente vinculada y de alternativas
compatibles. Las posiciones abiertas quedan fuera de este flujo.
