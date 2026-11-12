# Desarrollo y verificación

## Antes de editar

1. Confirmar raíz y estado con `git status --short --branch`.
2. Leer `AGENTS.md` y las notas relevantes de `ai_context/`.
3. Consultar el índice de `codebase-memory-mcp`; usar lectura directa si MQL5
   no está completamente indexado.
4. Identificar si el cambio afecta al protocolo o a ambos EAs.

## Versionado

Al publicar una nueva versión, mantener alineados el nombre del fichero,
`#property version`, `#property description` y el texto de panel que muestre la
versión. No cambiar una versión sólo por documentación externa al EA.

## Verificación

- Revisar el diff completo y buscar referencias de parámetros o funciones
  modificados.
- Compilar Master y Slave con MetaEditor cuando exista una ruta configurada.
  Los fuentes viven fuera del directorio de datos de MT5, así que hace falta
  indicar la carpeta `MQL5` que contiene `Include\Trade\Trade.mqh`:

  ```
  metaeditor64.exe /compile:"<ruta>\CopyMonitor_Slave_MT5_v1_37_MULTI.mq5" ^
                   /inc:"<terminal>\MQL5" /log:"<log>"
  ```

  El código de salida de MetaEditor no distingue el éxito: hay que leer la
  línea `Result:` del log, que está en UTF-16.
- La compilación no autoriza a adjuntar EAs, lanzar terminales ni tocar cuentas.
- `python -m unittest discover -s tools -p "test_*.py"` ejecuta las pruebas de
  los ayudantes Python y de las reglas de borrado de pendientes MT5. MQL5 no se
  puede ejecutar fuera de MetaTrader, así que
  `tools/test_pending_delete_rules.py` transcribe esas reglas y compara el
  cuerpo de las funciones del EA sin comentarios: si cambian, la prueba falla y
  obliga a revisar la transcripción en lugar de dejarla desfasada en silencio.
- Tras una compilación de entrega, mover la versión anterior a `compiled/MT5`
  o `compiled/MT4` y dejar junto a las fuentes únicamente los cuatro binarios
  vigentes. Las demás versiones históricas permanecen en esas carpetas.
- Para cambios de snapshot, verificar escritor y lector sobre el mismo esquema.
- Informar compilaciones o pruebas omitidas y por qué.

