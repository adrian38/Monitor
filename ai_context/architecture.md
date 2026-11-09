# Arquitectura

## Componentes

- `CopyMonitor_Master_MT5_v1_14_MULTI.mq5`: EA de sólo lectura operativa.
  Filtra posiciones y pendientes de la cuenta Master y publica un snapshot.
- `CopyMonitor_Slave_MT5_v1_19_MULTI.mq5`: EA de monitorización. Lee uno o
  varios snapshots, asigna operaciones por propietario, compara estado y emite
  diagnósticos o avisos. Puede borrar únicamente pendientes extra confirmadas.

## Flujo

1. El Master ejecuta `Cycle()` por temporizador y transacción de trading.
2. `Publish()` sobrescribe el snapshot del canal en `FILE_COMMON`.
3. El Slave ejecuta su `Cycle()` por temporizador y transacción.
4. Carga la configuración de propietarios, lee cada snapshot y comprueba
   frescura, posiciones y órdenes pendientes.
5. El panel, el log y Telegram muestran incidencias persistentes según la
   configuración de la instancia.

El fichero común permite que terminales MT5 diferentes de la misma máquina se
comuniquen sin red ni proceso intermedio.

