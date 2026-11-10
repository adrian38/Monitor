# Arquitectura

## Componentes

- `CopyMonitor_Master_MT5_v1_14_MULTI.mq5`: EA de sólo lectura operativa.
  Filtra posiciones y pendientes de la cuenta Master y publica un snapshot.
- `CopyMonitor_Slave_MT5_v1_23_MULTI.mq5`: EA de monitorización. Lee uno o
  varios snapshots, asigna operaciones por propietario, compara estado y emite
  diagnósticos o avisos. Puede borrar únicamente pendientes extra confirmadas.
- `CopyMonitor_Master_MT4_v1_00_MULTI.mq4` y
  `CopyMonitor_Slave_MT4_v1_03_MULTI.mq4`: los mismos dos EAs para MetaTrader
  4. Publican y leen el mismo snapshot, así que un Master de una plataforma
  puede alimentar a un Slave de la otra. Ver [mt4_port.md](mt4_port.md).

## Flujo

1. El Master ejecuta `Cycle()` por temporizador y transacción de trading.
2. `Publish()` sobrescribe el snapshot del canal en `FILE_COMMON`.
3. El Slave ejecuta su `Cycle()` por temporizador y transacción.
4. Carga la configuración de propietarios, lee cada snapshot y comprueba
   frescura, posiciones y órdenes pendientes.
5. El panel, el log y Telegram muestran incidencias persistentes según la
   configuración de la instancia.

El fichero común permite que terminales diferentes de la misma máquina se
comuniquen sin red ni proceso intermedio. MetaTrader 4 y MetaTrader 5 comparten
ese directorio, así que la pareja no tiene por qué ser de la misma plataforma.

