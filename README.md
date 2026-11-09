# CopyMonitor MT5

Monitor de consistencia entre una cuenta Master y una cuenta Slave de
MetaTrader 5. El proyecto no copia operaciones: publica el estado del Master,
compara las copias existentes en el Slave y avisa de diferencias.

## Componentes

- `CopyMonitor_Master_MT5_v1_14_MULTI.mq5`: publica posiciones abiertas,
  órdenes pendientes y el bróker Master en el directorio común de MetaTrader.
- `CopyMonitor_Slave_MT5_v1_17_MULTI.mq5`: compara uno o varios canales,
  comprueba volumen, precio de entrada, SL/TP y pendientes, y puede eliminar
  únicamente pendientes extra confirmadas.

Los terminales se comunican mediante
`FILE_COMMON/CopyMonitorMulti/CM_<channel>.txt`. No requieren sockets ni un
servicio intermedio.

## Seguridad

- El Master nunca opera.
- El Slave nunca abre ni cierra posiciones.
- El Slave puede corregir SL/TP y crear, modificar o borrar pendientes dentro
  del alcance documentado. Toda corrección espera primero que el problema
  persista y vuelve a validar el estado.
- Ninguna corrección se intenta sin permiso de trading ni con precios o
  volúmenes que el bróker deba rechazar: esos casos se avisan como `BLOQUEADO`
  sin tocar la cuenta.
- Telegram es opcional. Los tokens y chat IDs se configuran en MT5 y no deben
  guardarse en el repositorio.

## Configuración esencial

`InpPortfolioAlias` es obligatorio en el Slave: encabeza cada aviso de Telegram
junto con los números y los brokers de ambas cuentas. El EA no arranca si está
vacío.

`InpEnableTelegram` exige token y chat ID: activarlo sin credenciales dejaría al
usuario sin ningún aviso y sin saberlo, así que el EA tampoco arranca.

El snapshot va por el esquema `3`: el `2` añadió el bróker del Master y el `3`
añade el precio stop-limit de las órdenes pendientes. **Master y Slave se
despliegan juntos**, porque un Slave anterior rechaza el esquema `3` y
suspendería la vigilancia. Al revés sí hay compatibilidad: un Master de esquema
`1` o `2` se sigue leyendo, el aviso muestra `BROKER MASTER: NO DISPONIBLE` y la
copia de una STOP LIMIT queda bloqueada por falta del precio límite. Un esquema
que el Slave no entiende se avisa siempre como `CRÍTICO`.

El identificador de canal admite de 1 a 32 caracteres de `A-Z a-z 0-9 _ - .`:
Master y Slave derivan de él el mismo nombre de fichero y un carácter fuera de
ese juego podía dejar al Slave leyendo un fichero que nadie escribe.

En modo single-master, configura `InpMasterChannel`, el multiplicador y, si es
necesario, el comentario propietario. En modo multi-master, las cuatro listas
`InpMasterChannels`, `InpOwnerComments`, `InpMasterProfiles` e
`InpVolumeMultipliers` son posicionales y deben tener la misma longitud.

Cuando los brokers nombran un instrumento de forma diferente, usa
`InpSymbolMaps` con entradas `CANAL,SIMBOLO_MASTER,SIMBOLO_SLAVE` separadas por
punto y coma.

## Verificación

La comprobación estática del repositorio no abre MetaTrader:

```powershell
python -m tools.verify_project
```

Para una entrega, compila además ambos EAs con MetaEditor. Consulta
`ai_context/main.md` para el contrato técnico completo.

