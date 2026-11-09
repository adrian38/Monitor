# CopyMonitor MT5

Monitor de consistencia entre una cuenta Master y una cuenta Slave de
MetaTrader 5. El proyecto no copia operaciones: publica el estado del Master,
compara las copias existentes en el Slave y avisa de diferencias.

## Componentes

- `CopyMonitor_Master_MT5_v1_12_MULTI.mq5`: publica posiciones abiertas y
  órdenes pendientes en el directorio común de MetaTrader.
- `CopyMonitor_Slave_MT5_v1_15_MULTI.mq5`: compara uno o varios canales,
  comprueba volumen, precio de entrada, SL/TP y pendientes, y puede eliminar
  únicamente pendientes extra confirmadas.

Los terminales se comunican mediante
`FILE_COMMON/CopyMonitorMulti/CM_<channel>.txt`. No requieren sockets ni un
servicio intermedio.

## Seguridad

- El Master nunca opera.
- El Slave nunca abre ni cierra posiciones.
- La única acción automática posible es borrar una pendiente extra que
  pertenece a la instancia, no tiene ninguna pendiente Master que pueda
  justificarla y permanece extra durante el intervalo de confirmación.
- Telegram es opcional. Los tokens y chat IDs se configuran en MT5 y no deben
  guardarse en el repositorio.

## Configuración esencial

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

