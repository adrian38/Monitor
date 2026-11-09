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
- La compilación no autoriza a adjuntar EAs, lanzar terminales ni tocar cuentas.
- Para cambios de snapshot, verificar escritor y lector sobre el mismo esquema.
- Informar compilaciones o pruebas omitidas y por qué.

