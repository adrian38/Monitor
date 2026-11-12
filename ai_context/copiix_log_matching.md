# Emparejamiento con logs de Copiix en MT5

El auxiliar `tools/copiix_log_matches.py` correlaciona la confirmación de una
orden pendiente en el Journal Master con el primer envío `open` de Copiix en los
100 ms siguientes. Sólo acepta una asociación única en ambos sentidos. El log de
Experts Slave vincula ese mismo ID de Copiix con el ticket de la copia y su
Journal confirma la cuenta, el sentido y el tipo de pendiente. El resultado es
un índice que ata ticket Master con ticket de la copia.

## Qué autoridad tiene el índice

Esa asociación es exacta en el lado Slave e **inferida por tiempo en el lado
Master**. Hasta la v1.36 eso la dejaba en evidencia para avisos: cerraba una
ambigüedad y nada más. Desde la v1.37 el índice es una herramienta de
emparejamiento con autoridad operativa, porque es la única identidad exacta que
existe para una copia: el snapshot no publica ninguna relación entre los dos
tickets, y sin ella dos entradas gemelas no se pueden separar mirando sólo sus
valores.

Con `InpCopiixLinkAuthority` en `true`, que es el valor por defecto, la pareja
que identifica el índice es la que usa el monitor: se compara SL/TP contra ella
y se corrige sobre ella, igual que con cualquier otra pareja enlazada. En
`false` se vuelve al papel de la v1.36.

El enlace por índice es la **fase 0** del emparejamiento de posiciones, antes
que cualquier heurística, para que el resto del ciclo trabaje sobre la pareja
real y no sobre la más parecida. Sobre ella siguen rigiendo todas las demás
salvaguardas: `InpAutoFixPositionSLTP`, el tope de acciones por hora, la
desviación máxima de precio y el bloqueo por mercado cerrado.

Lo que el índice nunca puede hacer es imponer una pareja que los datos de ahora
desmientan. El Slave comprueba que el ticket candidato sigue visible bajo el
filtro y comentario del canal y que cumple las reglas vigentes de símbolo,
sentido, volumen y tolerancia de entrada. Además marca la copia como usada, de
modo que un índice incoherente no puede entregar la misma copia a dos tickets
Master. Sin índice válido no cambia nada: el emparejamiento por valores es el de
siempre.

El índice cubre **posiciones**, no pendientes. `CheckPending` mantiene sus
propias reglas y sus propios avisos de ambigüedad.

Cuando el índice cierra un aviso de ambigüedad, el mensaje dice que la identidad
viene de los logs de Copiix, en lugar de afirmar una unicidad que los valores
del snapshot no demuestran. El panel muestra por canal si el índice se está
leyendo y cuántas parejas está atando.

El Journal Slave puede repetir el mismo ticket durante el ciclo de vida de la
pendiente, incluida una línea posterior ya como operación de mercado. El
auxiliar conserva todos los tipos observados y exige que entre ellos esté el
sentido y tipo de pendiente exactos; la última línea nunca reemplaza por sí sola
la evidencia original.

## Quién publica el índice

El EA no lee los logs: lee el índice. Hasta la v1.36 ese índice sólo existía si
alguien dejaba corriendo el auxiliar a mano, uno por canal. Con
`InpUseCopiixLogMatches` en `true` y ningún proceso vivo, el Slave abría un
archivo inexistente y volvía en silencio a sus reglas habituales: el parámetro
parecía activo y no hacía nada.

Desde la v1.37 el Slave MT5 puede lanzar el auxiliar él mismo. `InpCopiixHelperScript`
es la ruta al `.py`; vacía, el comportamiento es el de siempre y el índice tiene
que publicarlo un proceso externo. Hacen falta además `InpCopiixMasterDataPath`,
porque la carpeta de datos del Master está en otro terminal y el Slave no puede
deducirla, y opcionalmente `InpCopiixPythonExe` (vacío usa el lanzador `py` de
Windows) e `InpCopiixRefreshSeconds`.

El lanzamiento se hace con `ShellExecuteW`, única DLL del EA, así que requiere
«Permitir importación de DLL» en las propiedades. La llamada queda detrás de
`MQL_DLLS_ALLOWED` y de la ruta configurada: sin permiso se dice una vez y se
deja de intentar, y una instalación que no use el auxiliar se comporta
exactamente igual que en la v1.36.

El EA invoca el auxiliar en modo de una sola pasada, nunca con `--interval`.
Un proceso corto que termina solo no deja huérfanos al quitar el EA, no se
duplica al recompilar y no hay que matarlo en `OnDeinit`: `ShellExecute` no
devuelve ningún handle con el que hacerlo. El refresco lo marca el propio EA al
final de cada ciclo, y lo que el auxiliar publique lo aprovecha el ciclo
siguiente; el índice vive 120 segundos, muy por encima del intervalo admitido
de 5 a 60.

En multi-master `InpCopiixMasterDataPath` admite una ruta para todos los canales
o una lista posicional separada por `;` con una por canal, porque dos canales
pueden venir de terminales Master distintos. Una lista de otra longitud se
rechaza al arrancar, como el resto de listas posicionales.

`ShellExecute` sólo confirma que el proceso arrancó, no que Python terminara
bien: una ruta de script equivocada arranca el intérprete y muere sin publicar
nada. Por eso, si el índice sigue sin poder leerse pasados tres refrescos desde
el primer lanzamiento, el EA lo dice una vez en el log en lugar de dejar al
usuario creyendo que está activo. Los fallos de arranque sí se ven: tras tres
seguidos se desiste y se informa.

## Uso manual

Sigue siendo válido ejecutarlo fuera del EA, y es la única opción si no se
quiere habilitar DLLs. Requiere Python 3.9 o posterior. Desde el repositorio,
ejecutar primero en modo de diagnóstico con las carpetas de datos de los dos
MT5:

```powershell
python tools/copiix_log_matches.py --master-data "<datos Master>" --slave-data "<datos Slave>" --master-account "<cuenta Master>" --slave-account "<cuenta Slave>" --channel "<canal>" --common-files "$env:APPDATA/MetaQuotes/Terminal/Common/Files" --dry-run
```

Para mantener el índice disponible sin el lanzador del EA, quitar `--dry-run`,
añadir `--interval 30` y habilitar `InpUseCopiixLogMatches` en el Slave. Una
ejecución por canal. Por defecto se revisan el día actual y el anterior. Para incluir
una fecha de apertura más antigua, indicar todas las fechas pertinentes con
`--date AAAA-MM-DD` repetido. El cruce admite las pendientes registradas con los
formatos de Journal y Experts indicados y cuyo ticket se conserva al activarse.

Los Journals y logs de Experts se abren únicamente en lectura. El auxiliar
publica por reemplazo atómico un archivo aparte en
`CopyMonitorMulti/CM_COPIIX_<canal>_<cuentaSlave>.txt`. No accede a
`Tickets.copiix` ni a los archivos `*-MANAGED.copiix`. El índice caduca a los
120 segundos. Un día con un log ausente, bloqueado o ilegible se omite.
Un índice ausente, incompleto, duplicado, caducado o de otra cuenta o canal
deja al Slave usando sus reglas habituales. El snapshot Master conserva su
esquema y formato.

La lectura de los logs usa un handle binario compartido y lo cierra en cuanto
ha tomado la foto de bytes; no bloquea ni escribe el archivo que MT5/Copiix
mantiene abierto para anexar. Si la foto termina a mitad de registro, esa última
línea se descarta hasta el siguiente ciclo. El Slave abre el índice publicado
con lectura y escritura compartidas, y el auxiliar reintenta brevemente el
reemplazo atómico si Windows conserva una lectura puntual sobre el nombre.
