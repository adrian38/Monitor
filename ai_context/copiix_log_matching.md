# Emparejamiento auxiliar con logs de Copiix en MT5

El Slave MT5 puede consultar un índice local cuando su emparejamiento habitual
detecta una ambigüedad entre posiciones activas. El auxiliar
`tools/copiix_log_matches.py` correlaciona la confirmación de una orden pendiente
en el Journal Master con el primer envío `open` de Copiix en los 100 ms siguientes.
Sólo acepta una asociación única en ambos sentidos. El log de Experts Slave
vincula ese mismo ID de Copiix con el ticket de la copia y su Journal confirma
la cuenta, el sentido y el tipo de pendiente. La asociación en el Master se
infiere por hora, por lo que es evidencia para avisos, sin autoridad de trading.

El Slave comprueba que el ticket candidato sigue visible bajo el filtro y
comentario del canal y que cumple las reglas vigentes de símbolo, sentido,
volumen y tolerancia de entrada. Si los niveles habilitados también coinciden,
cierra el aviso de ambigüedad con la explicación del cruce. Si difieren, mantiene
el aviso y añade el ticket sugerido. El índice no modifica las asignaciones
operativas ni autoriza cambios de SL/TP, creación o eliminación de pendientes.

El Journal Slave puede repetir el mismo ticket durante el ciclo de vida de la
pendiente, incluida una línea posterior ya como operación de mercado. El
auxiliar conserva todos los tipos observados y exige que entre ellos esté el
sentido y tipo de pendiente exactos; la última línea nunca reemplaza por sí sola
la evidencia original.

## Uso

Requiere Python 3.9 o posterior. Desde el repositorio, ejecutar primero en
modo de diagnóstico con las carpetas de datos de los dos MT5:

```powershell
python tools/copiix_log_matches.py --master-data "<datos Master>" --slave-data "<datos Slave>" --master-account "<cuenta Master>" --slave-account "<cuenta Slave>" --channel "<canal>" --common-files "$env:APPDATA/MetaQuotes/Terminal/Common/Files" --dry-run
```

Para mantener el índice disponible, quitar `--dry-run`, añadir
`--interval 30` y habilitar `InpUseCopiixLogMatches` en el Slave. Una ejecución
por canal. Por defecto se revisan el día actual y el anterior. Para incluir
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
