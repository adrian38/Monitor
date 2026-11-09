# Instrucciones para agentes

## Alcance

- Este repositorio es `Monitor` y contiene dos Expert Advisors MQL5: el
  publicador Master y el monitor Slave.
- Leer primero [ai_context/main.md](ai_context/main.md) y después la nota del
  área afectada.
- Preservar cambios ajenos y limitar cada modificación al objetivo pedido.
- No operar terminales MT5, cuentas, órdenes ni Telegram por iniciativa propia.
  Compilar y ejecutar pruebas estáticas es seguro; una prueba en cuenta o un
  reinicio requiere una petición explícita del usuario.

## Descubrimiento de código y MCP

Este proyecto usa `codebase-memory-mcp` como herramienta principal de
descubrimiento. Al iniciar una tarea de código:

1. comprobar o crear el índice del checkout actual;
2. usar `search_graph`, `search_code` y `trace_path` para símbolos y flujos;
3. usar `get_code_snippet` sólo con nombres devueltos por el grafo;
4. recurrir a `rg` y lectura directa para texto, parámetros, formatos de
   snapshot o cuando el índice no cubra MQL5 correctamente;
5. reindexar después de cambios estructurales.

Si el MCP no está disponible o el parser no reconoce una construcción MQL5,
continuar con lectura directa y declarar esa limitación en la entrega. Un
resultado negativo del grafo no demuestra que un símbolo no exista.

## Contratos que no deben romperse

- Master y Slave se comunican por archivos comunes
  `CopyMonitorMulti\CM_<channel>.txt`.
- El formato actual del snapshot es lineal: `META`, cero o más `POS`, cero o
  más `ORD`, y `END`. Cambiar campos, orden, separadores o semántica exige
  actualizar y verificar ambos EAs como una sola unidad.
- El Master sólo publica estado; no debe realizar acciones de trading.
- El Slave monitoriza posiciones y nunca autocierra posiciones abiertas.
- La eliminación automática se limita a órdenes pendientes extra que sean
  propiedad de la instancia y hayan superado la confirmación configurada.
- En modo multi-master, las listas de canales, comentarios, perfiles y
  multiplicadores son posicionales y deben conservar la misma longitud.
- Los filtros de símbolos se aplican en el lado indicado por cada parámetro;
  la lista de exclusión prevalece sobre la de inclusión.
- Nunca registrar ni versionar tokens de Telegram, IDs privados, credenciales,
  números de cuenta reales o configuraciones locales sensibles.

## Flujo de trabajo

- Antes de editar, revisar `git status --short --branch` y buscar el tema en
  `ai_context/`.
- Mantener `#property version`, nombre del fichero, descripción visible y
  mensajes del panel coherentes cuando cambie una versión.
- Para correcciones de protocolo o matching, revisar tanto Master como Slave,
  incluso si el cambio parece local.
- Preferir funciones pequeñas con nombres explícitos; no ocultar reglas de
  negocio en expresiones compactas.
- Editar código con parches y revisar el diff completo.

## Verificación y entrega

- Compilar ambos `.mq5` con MetaEditor cuando esté disponible, sin lanzar MT5.
- Si no hay compilador configurado, realizar al menos revisión estática del
  diff, búsquedas de referencias y validación del protocolo compartido.
- Una tarea termina con el diff revisado, el estado Git conocido y todas las
  comprobaciones aplicables informadas, incluidas las omitidas.
- Toda decisión técnica duradera nueva se documenta en `ai_context/` y se añade
  al índice de `ai_context/main.md`.

