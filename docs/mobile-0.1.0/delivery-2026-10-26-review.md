# Entrega para revisión de Codex — 26 de octubre de 2026

Documento de traspaso. No es una aprobación: PASS, FAIL y NO EJECUTADO están
separados y las pruebas fallidas conservan su `.xcresult`, log y capturas.

## Repositorios y PRs

| Repo | Rama | Commit de código | PR |
| --- | --- | --- | --- |
| `nodus` Desktop | `codex/mobile-0.1.0-parity` | `6fec24dcc60a4833ca9df7805f3fbbd2009634d2` | https://github.com/jorgepb96/nodus/pull/1089 |
| `nodus-mobile` | `codex/mobile-0.1.0-parity` | `8c13a1b` | https://github.com/jorgepb96/nodus-mobile/pull/30 |

Desktop parte de `121b46de` (merge con main `03fa249b` y empaquetado de workers).
Ningún PR se fusionó. Los checks automáticos creados por los pushes de este head
se cancelaron; no se lanzó CI completa.

## Desktop: cambios y verificación

- `operations.ts`: el puente permite `studyImproveLastStyleId` y
  `studyImproveToolbarStyleIds`. Antes la superficie de escritura recibía
  `settings_forbidden` al elegir el prompt de mejora.
- `spaceActionProcessor.ts`: `writing.generate` resuelve una vez el modelo efectivo
  del Mac y lo guarda en `writing_saved_drafts.model_json`.
- `npm run typecheck` PASS; ESLint de ambos archivos PASS; `test-mobile-space-actions`,
  `test-mobile-writing-workshop` y `test-mobile-parity-transport` 7/7 PASS.
- Host del laboratorio reconstruido desde `6fec24dcc` (PID actual en
  `artifacts/review-2026-10-26/lab-host-05.pid`, puerto 52172). Smoke de
  `backgroundUtility` + `documentaryRetrievalWorker`: PASS, 2 consultas × 4 pasajes,
  identidad canónica y hashes en `artifacts/review-20261026/worker-smoke-final.log`.

## Móvil: cambios

- `FamilyTreeView`: `Layout` propio que coloca cada tarjeta en su punto con su marco
  real, canvas ajustado al viewport, recentrado tras layout/tamaño/foco/zoom y botón
  de centrado de 44 pt.
- `PagesDatabasesViews`: el inspector compacto lleva su fila, sobrevive a una recarga
  de vista guardada y el tablero expone el selector de carriles.
- `SharedDesktopSurface`/`MobileJavaScriptDelivery`: un fallo de entrega de contenido
  se convierte en error visible, no en una vista que queda cargando.
- Recursos compartidos regenerados desde Desktop `6fec24dcc`; inventario de paridad
  78 rutas/1.836 acciones/97 tablas (inventario, no paridad funcional).
- Pruebas nuevas/ajustadas: `CompanionPageEditingUITests`, recuperaciones de sólo
  lectura para diccionario, inmersión, taller y Deep Research, árbol con paneo en dos
  ejes, base de datos 29 propiedades, página corta, tablero compacto y teclado nativo.

## Resultados nativos en iOS 26.5

### PASS

- Árbol, iPhone: `phone-tree-03` PASS. iPad: `ipad-tree-02` PASS. Incluye búsqueda,
  parentesco, pedigree, rotaciones, selección y ficha completa.
- Base de datos 29 propiedades: `phone-db29-05` PASS; `ipad-db29-04` PASS.
- Página corta de fila: `phone-rich-page-01` e `ipad-rich-page-01` PASS.
- Edición manual de página: `phone-page-edit-04` PASS y reapertura. Verificación
  independiente en SQLite: `page-edit-desktop-verification-02.json` (4 bloques
  originales semánticamente intactos, párrafo nuevo con marcador, sin duplicado del
  mismo marcador).
- Tablero de demostración compacto: `phone-db-demo-02` PASS.
- Diccionario: generación real `ff4b1ea9-…` completada, versión `dd8f6162-…`,
  `gemini/gemini-2.5-flash`, oráculo 6/6 PASS, reapertura `phone-dictionary-recovery-06`
  PASS.
- Inmersión: sesión `cef83d81-…` generada y oráculo 6/6 PASS; progreso iniciado,
  guardado y reabierto en `phone-immersion-recovery-02` PASS.
- Taller: borrador `9b4f7bd2-…` guardado; `phone-workshop-recovery-01` PASS
  (búsqueda, prosa real, reapertura). Oráculo 4/5: PASS de notas originales,
  entidad única y exacta; **FAIL sólo de procedencia** porque esa ejecución guardó
  `model_json` nulo (el arreglo de Desktop es posterior).
- Deep Research: informe `3f5359c3-…`, `gemini/gemini-2.5-flash`, oráculo 5/5 PASS;
  lector nativo y reapertura `phone-deep-research-recovery-03` PASS.

### FAIL conservados

- Escritura: `live-writing-improve-04` generó la propuesta y la pantalla «Revisa la
  propuesta», pero el test falló al leer el editor cubierto; `live-writing-improve-05`
  (reintento controlado) aceptó localmente y perdió la conexión antes de sincronizar.
  La nota sigue con el contenido original (535 bytes, hash `78febf58…`), no hay
  acción `replace` y la recuperación `phone-writing-recovery-01` falla. **NO aprobado**;
  no se compró otra generación.
- Oráculo de taller: `saved_provider_and_model_match_baseline_role` FAIL por
  `model_json` nulo en la ejecución anterior al arreglo. El modelo efectivo consta en
  los ajustes del LAB (`writingModel = gemini/gemini-2.5-flash`) y en la inferencia
  del puente, pero no se usa para declarar PASS de esa comprobación.

### NO EJECUTADO

- iPhone físico, VPN/Tailscale real, cámara de QR y TestFlight/App Store.
- La generación real de taller/escritura no se repitió para no volver a comprar
  resultados tras las caídas de automatización.

## Evidencias

- Móvil: `artifacts/review-2026-10-26/` (logs, `.xcresult`, `*-binding.json`,
  `*-summary.json`, capturas y configuraciones privadas 0600).
- Desktop: `artifacts/review-20261026/` (typecheck, ESLint, pruebas de acciones,
  smoke de workers, build del laboratorio).
- Build final: `review-fixes-final-build-02`; el recibo
  `Nodus.app.acceptance-build.json` liga commit, digest de fuentes y artefactos.
- Los logs que pueden contener códigos se leen con
  `artifacts/interface-2026-10-18/read-log-tail.py`; no se copiaron credenciales.

## Reproducción

1. En Desktop, `npm run typecheck`, ESLint de los archivos tocados y las pruebas de
   acciones/transporte/taller.
2. Reconstruir el host con `node scripts/build-mobile-acceptance-bridge.mjs` y
   ejecutar el smoke con `NODUS_MOBILE_ACCEPTANCE_LAB` y Electron sin
   `ELECTRON_RUN_AS_NODE`.
3. En móvil, `xcodegen generate --spec ios/project.yml`,
   `build-shared-desktop.mjs --verify` y `generate-parity-manifest.mjs`.
4. `build-acceptance-app.mjs <intento-nuevo> <simulador> <derived-data> simulator`.
5. Ejecutar los `xctestrun` registrados con `run-native-local.mjs` (siempre
   `-collect-test-diagnostics never`), empezando por árbol, DB29 y página manual.
6. Para generación real, usar los `Nodus-live-principal-*-review-01.xctestrun` y el
   oráculo; no reenviar un trabajo existente.

## Pendiente exclusivamente de revisión/distribución

- Revisar el código y contrastar esta evidencia.
- Decidir si el fallo de escritura y la procedencia del taller bloquean la beta.
- Distribución por el propietario desde el navegador integrado; nunca Chrome.
