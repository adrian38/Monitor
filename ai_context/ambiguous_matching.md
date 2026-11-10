# Posiciones y pendientes indistinguibles

## El caso

Dos operaciones abiertas a la vez sobre el mismo símbolo, con el mismo tipo,
el mismo volumen y el mismo precio de entrada son indistinguibles con los
campos que publica el snapshot: el ticket del Master no guarda ninguna
relación con el del Slave. Si el Master mueve el SL o el TP de una de ellas,
el emparejamiento por cercanía de precio empata y la elección dependía del
orden en que el terminal devolvía las colecciones. El monitor podía así
corregir la posición equivocada, y además cambiar de pareja de una evaluación
a la siguiente.

## Ningún enlace queda al azar

El emparejamiento es una función de los datos, no del orden de las
colecciones. Dos reglas lo garantizan:

- **Recorrido por ticket ascendente.** Las copias del Slave se ordenan por
  ticket y las entradas del Master se recorren por ticket, en los dos lados y
  en todas las fases. El orden que devuelve el terminal cambia en cuanto se
  cierra cualquier otra entrada; el ticket no.
- **Empate resuelto por el ticket más bajo.** Un coste de emparejamiento sólo
  desplaza al anterior si lo mejora por encima de `CM_MATCH_EPS`, que únicamente
  absorbe el ruido de coma flotante. Por debajo de ese margen gana la copia más
  antigua. Como los dos brókeres numeran de forma creciente, eso reproduce el
  orden de apertura.

El resultado es siempre el mismo con los mismos datos, y una pareja no salta
entre evaluaciones: las claves de alerta (`canal|ticket_master|ticket_slave`)
dejan de rotar y la persistencia previa a corregir no se reinicia.

## Fases del emparejamiento

Iguales para posiciones y para pendientes:

1. **Desempate por valores.** Sólo interviene cuando una entrada Master admite
   dos o más copias libres compatibles. Entre ellas se ata la que ya coincide
   en todo lo que el Slave compara: SL y TP en posiciones; precio de entrada,
   precio límite, SL y TP en pendientes. Los campos desactivados por
   configuración no participan, y sin ninguna comprobación de niveles activa
   el desempate no se aplica. Es el mismo razonamiento que se hace a mano al
   mirar los dos SL y TP del Master: la copia que ya está en orden es la de la
   entrada que no se tocó, así que la que queda libre es la que hay que
   corregir.
2. **Protección de tickets Master ignorados.** Lo que no se ató en la fase 1
   se empareja por cercanía de precio y se retira de las comprobaciones.
3. **Monitorización del resto.** Cada entrada Master usa la pareja que traiga
   de la fase 1 y, si no tiene, la copia libre más cercana en precio.

Una sola candidata compatible nunca entra en la fase 1: sin ambigüedad el
precio ya decide y el desempate no debe alterar ese resultado.

## Cuando no hay nada que distinga

Si al emparejar por precio varias copias empatan en la distancia mínima, la
pareja la fija el orden de apertura y no un dato de la operación. Eso es
estable y reproducible, pero no es una identidad, así que el bloque de
diferencia del aviso termina con un `AVISO` que lo dice y pide revisarlo a
mano. Ver [telegram_messages.md](telegram_messages.md).

## Límites conocidos

- El desempate no demuestra identidad, sólo resuelve el empate con la
  información disponible. Si el propio copiador cruzó los niveles al abrir las
  dos copias, el desempate consolida ese cruce y no lo denuncia. No hay forma
  de distinguirlo desde el snapshot actual.
- Si el Master deja las dos entradas con los mismos valores, cualquier
  asignación es equivalente y el resultado en la cuenta es el mismo.
- Si el Master mueve los niveles de las dos entradas gemelas a la vez, ninguna
  copia coincide y la pareja se fija por orden de apertura. Con `InpCheckStopLoss`
  y `InpCheckTakeProfit` ambos activos la cuenta converge igualmente al
  conjunto correcto de SL y TP; con sólo uno activo, un emparejamiento cruzado
  puede producir híbridos (SL de una entrada con TP de la otra), un estado que
  no existe en el Master. Ese caso lleva siempre el `AVISO` del apartado
  anterior.
- Publicar la hora de apertura no resolvería el caso: dos entradas simultáneas
  se separan por milisegundos y la latencia del copiador puede invertir el
  orden en el Slave. La única identidad exacta sería que el copiador escribiera
  el ticket Master en el comentario de la copia, cosa que no depende de estos
  EAs.

Ver [pending_matching.md](pending_matching.md) y
[protocol_and_safety.md](protocol_and_safety.md).
