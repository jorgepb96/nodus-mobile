# Correcciones de revisión — 26 de octubre de 2026

Estado: **listo para revisión de Codex**, no aprobado ni distribuido.

## Integración Desktop

- Desktop `121b46de` ya incluía main 5.16.1 y el empaquetado de los workers de
  recuperación documental. Esta sesión añade `6fec24dcc`:
  - el puente permite `studyImproveLastStyleId` y `studyImproveToolbarStyleIds`,
    preferencias de la superficie de escritura que antes abortaban una mejora con
    `settings_forbidden`;
  - una acción móvil `writing.generate` resuelve una sola vez el modelo efectivo
    del Mac y lo persiste en `writing_saved_drafts.model_json`.
- Typecheck, ESLint de los dos archivos y 7/7 pruebas de acciones móviles, taller y
  transporte PASS. El host del laboratorio se reconstruyó desde `6fec24dcc`; el
  smoke de workers documentales PASS (2 consultas, 4 pasajes cada una).

## Móvil

- Árbol: pase en iPhone y iPad con búsqueda, parentesco, pedigree, rotaciones,
  selección y ficha completa. Queda compilado el `Layout` que coloca las tarjetas
  por sus límites reales y recentra tras layout, tamaño, foco o zoom.
- Base de datos 29 propiedades: pase en iPhone y iPad, incluidas relaciones,
  adjunto, rotaciones, página y reapertura. La página vinculada carga tras corregir
  el bucle de `onDocumentChange` en Desktop.
- Edición manual de la página de fila: pase; verificación independiente en SQLite
  confirma el párrafo nuevo y los cuatro bloques originales semánticamente intactos.
- Portada de demostración de bases de datos: pase en iPhone con el selector compacto
  de carriles.
- Generación real: diccionario, inmersión y Deep Research completaron sus trabajos y
  se recuperaron sin volver a comprarlos; sus lecturas/reaperturas pasan con pruebas
  de sólo lectura. Taller guardó el borrador y su reapertura pasa; el oráculo no puede
  acreditar `model_json` porque esa ejecución se guardó antes del arreglo de
  procedencia.
- Mejora de escritura: la generación y la pantalla de revisión se produjeron, pero la
  conexión cayó antes de sincronizar; la nota permanece intacta y `explicit_replace`
  no se registró. **No se aprueba** y no se repitió la generación.
