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

El emparejamiento sólo acepta una pareja cuando los datos producen una única
candidata **en ambos sentidos**. No basta con que una Master vea una sola
Slave: esa Slave debe identificar también a una sola Master todavía libre. Si
dos Master podrían reclamar la misma copia, asignarla a la primera por orden de
recorrido convertiría a la segunda en una falsa faltante y, para pendientes,
podría crear un duplicado. `CM_MATCH_EPS` absorbe exclusivamente ruido de coma
flotante; el ticket, el orden del array o el orden de apertura no deciden la
identidad.

Las colecciones se recorren por ticket para que la evaluación y los avisos sean
reproducibles, pero ese orden nunca desempata una pareja. Una ambigüedad
persistente se avisa y queda fuera de toda corrección automática.

## Fases del emparejamiento

Las posiciones y las pendientes comparten estas fases:

1. **Identificación por valores.** Interviene cuando una entrada Master admite
   dos o más copias libres compatibles o cuando se evalúan pendientes en MT5.
   Se enlaza la candidata que coincide
   en todo lo que el Slave compara: SL y TP en posiciones; precio de entrada,
   precio límite, SL y TP en pendientes. Los campos desactivados por
   configuración no participan, y sin ninguna comprobación de niveles activa
   esta identificación no se aplica. La candidata coincidente también debe ser
   única; dos coincidencias iguales siguen siendo ambiguas. Es el mismo razonamiento que se hace a mano al
   mirar los dos SL y TP del Master: la copia que ya está en orden es la de la
   entrada que no se tocó, así que la que queda libre es la que hay que
   corregir.
2. **Protección de tickets Master ignorados.** Lo que no se ató en la fase 1
   se empareja por cercanía de precio y se retira de las comprobaciones.
3. **Monitorización del resto.** Cada entrada Master usa la pareja que traiga
   de la fase 1 y, si no tiene, una copia libre sólo cuando es la única más
   cercana en precio y la copia no encaja a la vez con otra Master libre.

4. **Volumen distinto, en una segunda pasada.** Lo que se quedó sin copia
   exacta se vuelve a mirar ignorando el volumen. Esta pasada va *después* de
   que todas las entradas Master hayan tomado la suya, y el motivo es el mismo
   que gobierna todo lo demás: el recorrido es por ticket, no por prioridad.
   Si se resolviera dentro del bucle principal, una Master de 0.10 podría
   reclamar la copia de 0.20 que pertenece a una Master de 0.20 todavía sin
   evaluar, sólo por tener el ticket más bajo. Aplazarla garantiza que una
   copia con otro volumen se asigna únicamente cuando ya no la encaja
   exactamente nadie más. Sigue exigiéndose candidata única desde los dos
   lados; si varias Master pueden explicar la misma copia de volumen distinto,
   todas quedan protegidas y se avisa de ambigüedad sin crear ni modificar.

En MT5 desde la v1.33, una única pendiente Slave también entra en la primera
fase. Dos pendientes Master pueden compartir símbolo, tipo y volumen y tener
precios diferentes. Si la copia coincide en valores sólo con una de ellas,
se le asigna antes de evaluar la otra. Justo antes de crear, y al reconciliar
un envío con resultado incierto, se repite esa asignación sobre el snapshot
actual y las órdenes vivas. Una candidata restante que pueda ser la copia
bloquea la creación hasta que se pueda identificar.

## Cuando no hay nada que distinga

Si varias copias empatan para una Master, o una copia encaja con varias Master,
no se enlaza ninguna. Se envía una `ALERTA` que pide revisión manual y se
bloquean las modificaciones de las candidatas. En pendientes, el Master se
considera cubierto sólo a efectos de no crear un duplicado, y las candidatas no
se consideran extras borrables. Ver [telegram_messages.md](telegram_messages.md).

## Límites conocidos

- La identificación por valores no puede descubrir que el propio copiador
  cruzó los niveles al abrir dos copias. No hay identidad externa en el
  snapshot actual con la que demostrarlo.
- Si el Master deja las dos entradas con los mismos valores, cualquier
  asignación es equivalente y el resultado en la cuenta es el mismo.
- Si el Master mueve los niveles de dos entradas gemelas a la vez y ninguna
  copia conserva valores que permitan identificarla, se avisa y no se corrige
  ninguna automáticamente.
- Publicar la hora de apertura no resolvería el caso: dos entradas simultáneas
  se separan por milisegundos y la latencia del copiador puede invertir el
  orden en el Slave. La única identidad exacta sería que el copiador escribiera
  el ticket Master en el comentario de la copia, cosa que no depende de estos
  EAs.

Ver [pending_matching.md](pending_matching.md) y
[protocol_and_safety.md](protocol_and_safety.md).
