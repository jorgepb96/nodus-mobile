# Nodus desktop — la Bandeja de entrada

Implementa la mitad de escritorio de una función cuya mitad móvil ya está hecha y en `main` de
`nodus-mobile` (rama `claude/mobile-dr-reports-nodus-918f7e`). Trabaja en
`/Users/jorgepb96/Documents/GitHub/nodus`. Haz commits pequeños e independientes.

## Qué existe ya, y qué falta

El iPhone genera informes de Deep Research y ahora los **envía de verdad**: los pone en
`writing_saved_drafts` como mutación, con `brief_json.kind = "deep_research"`, y los sube al
ledger del servidor. Eso ya funciona.

Del lado del escritorio hay tres agujeros, verificados leyendo el código:

1. **El escritorio no drena el ledger por su cuenta.** `collectMutations`
   (`electron/serverSync/serverSyncService.ts:338`) tiene **una sola** llamada: dentro de
   `publishVault`, en la línea 439, bajo `if (vault.active)`. Y `publishVault` solo corre cuando
   el vault activo se ensucia (60 s de calma + 2 min de intervalo mínimo) o cuando el usuario
   pulsa «Publicar ahora». **Una mutación entrante no ensucia nada.** Así que después de la
   pasada de arranque (~5 s), un escritorio ocioso no recoge nada, nunca.
2. **Nada registra lo que llegó.** `rt.lastInbox` (`serverSyncService.ts:61`) se asigna en la
   línea 355 y **no se lee en ningún sitio** — tres apariciones en todo el repo, todas en ese
   fichero. Las filas aplicadas no llevan procedencia: `IncomingMutation.clientId`
   (`mutationInbox.ts:25`) está declarado y nunca se lee.
3. **Un borrador recién llegado no aparece.** `DeepResearchView` relee los borradores solo al
   montarse (`src/views/DeepResearchView.tsx:334`), al completarse un trabajo local, ante un
   trabajo de origen `mcp`, y en `backToGallery()`. No sondea y no está suscrito a nada.

Hay que cerrar los tres, y darle al propietario una **Bandeja** en la cabecera.

---

## B1 · Tabla `server_inbox` (migración v123)

En `electron/db/migrations.ts`: sube `SCHEMA_VERSION` (línea 12) a `123` y añade la migración al
final del array, con el mismo estilo de comentario en el `up` que usa la v122 (línea 6205).

```sql
-- Lo que ha llegado de otro dispositivo a través del ledger, y qué se hizo con ello.
--
-- Existe porque `applyIncomingMutations` no dejaba rastro: la fila aplicada es
-- indistinguible de una que escribiera el propietario, y el resumen en memoria se
-- perdía al cerrar. Sin esto no hay forma de decirle a nadie que ha recibido algo.
CREATE TABLE server_inbox (
  id             TEXT PRIMARY KEY,   -- el id de la mutación: un reintento es idempotente
  seq            INTEGER NOT NULL,
  space_id       TEXT,
  client_id      TEXT,               -- qué dispositivo, no qué persona: el servidor
                                     -- escribe `userId: null` siempre (api.mjs:432)
  table_name     TEXT NOT NULL,
  row_key        TEXT NOT NULL,      -- JSON.stringify(mutation.key), la MISMA codificación
                                     -- que server_outbox y las lápidas
  op             TEXT NOT NULL CHECK (op IN ('upsert','delete')),
  outcome        TEXT NOT NULL CHECK (outcome IN ('applied','deleted','kept_local','refused')),
  reason         TEXT,
  title          TEXT,
  entity_kind    TEXT,               -- 'deep_research' | 'note' | … para no reparsear brief_json
  schema_version INTEGER,
  created_at     TEXT,               -- cuándo lo escribió el teléfono
  arrived_at     TEXT NOT NULL,      -- cuándo lo aplicó este escritorio
  read           INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_server_inbox_recent ON server_inbox(arrived_at DESC);
CREATE INDEX idx_server_inbox_unread ON server_inbox(read, arrived_at DESC);
```

**No la añadas** a `MUTABLE_TABLES` (`electron/serverSync/outboxTriggers.ts:32`) ni a
`serverSnapshot.ts`. Es el registro que ESTE ordenador lleva de lo que le llegó; publicarlo o
dejar que viaje sería lo mismo que el comentario de `sync_superseded` en
`electron/db/syncTables.ts` ya explica para su propio caso. Añádela a `NOT_SYNCED_TABLES` en ese
mismo fichero, o `describeSyncCoverage()` la reportará como sin clasificar.

## B2 · `applyIncomingMutations` devuelve el detalle; no escribe

`electron/serverSync/mutationInbox.ts`. Extiende `InboxSummary` (línea 34) con:

```ts
entries: {
  id: string; seq: number; clientId?: string;
  table: string; key: unknown[]; kind: 'upsert' | 'delete';
  outcome: 'applied' | 'deleted' | 'keptLocal' | 'refused';
  reason?: string;
  title?: string | null;
  entityKind?: string | null;
  schemaVersion?: number;
  createdAt?: string;
}[];
```

Empuja una entrada en **cada** punto que hoy incrementa un contador o apila un rechazo: los
cuatro `keptLocal` (líneas 99, 110, 116, 127), el `deleted` (103), el `applied` (139) y los
cuatro rechazos (74, 78, 84, 143). La función ya conoce todos esos casos; hoy tira el detalle.

**No escribas en la base de datos desde dentro de `applyIncomingMutations`.** Dos razones
concretas: tiene seis llamadas, cinco de ellas en scripts de prueba
(`scripts/test-connected-vault-replica.mjs:172,185,193,258` y
`scripts/verify-connected-vault-live.mjs:296`) que pasan bases temporales; y la de la línea 185
**repite el mismo lote a propósito**. Una escritura incondicional produciría filas de bandeja
durante los tests y chocaría o resucitaría en la repetición. Que registre el llamador.

Antes de dar esto por bueno, `grep` que ninguna aserción existente compare el resumen entero con
`deepEqual` — hoy todas son por campo (`summary.applied`, `summary.refused`, `late.keptLocal`),
así que añadir un campo no rompe nada, pero compruébalo en vez de confiar.

Añade un `titleOf(table, row)` puro en el mismo fichero, sin consultas:
- `writing_saved_drafts` → `row.title`, y si falta `JSON.parse(row.brief_json).objective`;
  `entityKind = 'deep_research'` cuando `brief_json.kind === 'deep_research'`. **Este es el que
  importa**: es el informe que manda el teléfono.
- `notes` → `row.title`; `note_folders` → su columna de nombre.
- El resto → `null`, y el panel muestra `tabla · clave`.
- Un `delete` no lleva fila, así que no hay título y el panel cae en la clave.

## B3 · `electron/db/serverInboxRepo.ts`

Modelado sobre `electron/db/writingDraftsRepo.ts`: una interfaz `Row`, un mapeador que devuelve
`null` en vez de lanzar, y `getDb()`.

```ts
export function recordServerInbox(entries: InboxSummary['entries'], ctx: { spaceId: string }): void
export function listServerInbox(limit = 200): ServerInboxEntry[]   // ORDER BY arrived_at DESC, seq DESC
export function unreadServerInboxCount(): number
export function markServerInboxRead(id?: string): void             // una, o todas si no hay id
export function clearServerInboxEntry(id: string): boolean
export function clearServerInbox(): number
```

`recordServerInbox` escribe el lote en un solo `db.transaction`.

**La cláusula de conflicto es lo importante.** Un rechazo detiene el bucle de aplicación
(`mutationInbox.ts:75/79/85/144`) y **no avanza el cursor**, así que la misma mutación rechazada
se vuelve a pedir y a rechazar cada 30 segundos, para siempre. Usa:

```sql
INSERT INTO server_inbox (...) VALUES (...) ON CONFLICT(id) DO NOTHING
```

`INSERT OR REPLACE` pondría `read` a 0 en cada sondeo y daría una insignia de no leídos que el
usuario no puede quitar nunca. `DO UPDATE SET arrived_at = …` haría que una mutación
permanentemente rechazada fuese permanentemente lo más nuevo de la bandeja. El primer registro
de lo que pasó es el verdadero; volver a rechazar no es noticia.

**IPC** en `electron/ipc/platform.ts`, junto a los `nodusServer:*` de las líneas 84-88. Devuelve
la lista fresca desde los mutadores, como hace `nodi:notifications:markRead`
(`electron/ipc.ts:374`):

```ts
h('nodusServer:inbox:list',     async () => listServerInbox());
h('nodusServer:inbox:markRead', async (_e, id?: string) => { markServerInboxRead(id); return listServerInbox(); });
h('nodusServer:inbox:clear',    async (_e, id?: string) => { id ? clearServerInboxEntry(id) : clearServerInbox(); return listServerInbox(); });
```

**Preload** en `electron/preload/platform.ts`, que está tipado como `PlatformApi` — el compilador
garantiza que la porción esté completa, así que añade las firmas a `shared/api/platform.ts`
(junto a `getNodusServerOverview`) y el tipo `ServerInboxEntry` a `shared/types.ts` junto a
`NodusServerConnection` (línea 3811).

Deja constancia en un comentario de que **esta bandeja es por vault** (vive en la base del
vault), a diferencia de la bandeja de salida del iPhone, que es deliberadamente global. Una
entrada pertenece al vault en el que aterrizó.

## B4 · El sondeo de 30 segundos, sin bloquear la interfaz

Módulo nuevo `electron/serverSync/inboxPoller.ts`, **aparte** de `serverSyncService.ts`, cuyo
booleano de módulo `publishing` (líneas 73 y 420) y cuyas puertas de `autoSync` (537, 554-555)
son justamente lo que hay que esquivar.

**Quita `collectMutations` de `publishVault`** (línea 439) y deja el sondeo como único lector del
ledger. Esto elimina la pregunta de la concurrencia en vez de responderla: better-sqlite3 es
síncrono y ambos correrían en el mismo hilo del proceso principal, así que «nunca a la vez»
sería una bandera compartida entre dos módulos, que es un fallo esperando a ocurrir.

El comentario de las líneas 433-437 defiende recoger *antes* de construir el snapshot, para que
el trabajo de un colaborador vuelva a salir en la misma publicación. Consérvalo de otra forma:
tras aplicar, el sondeo llama a un `markVaultDirty(vaultId)` nuevo y exportado desde
`serverSyncService.ts` (que ponga `ensureRuntime(vaultId).pending = true`), y la siguiente
publicación lo recoge. El resultado es estrictamente mejor que hoy, donde un escritorio ocioso no
drena jamás.

Exporta también `isPublishing()` y salta el tick mientras haya una publicación en vuelo:
`buildServerSnapshot` retiene la base durante un tramo síncrono largo.

En vez de reexportar internos, mueve `normalizeUrl`, `fetchWithTimeout`, `VaultServerConfig` y
`readVaultConfig` a un `electron/serverSync/serverSyncShared.ts` que importen los dos módulos.

El tick:

```
if (isPublishing()) return;
config = readVaultConfig(getActiveVault());
if (!config.configured || !config.enabled) return;   // `enabled` ES el interruptor de pausa
token = getNodusServerTokenFor(config.vaultId); if (!token) return;
db = getDb();

for (let batch = 0; batch < MAX_BATCHES_PER_TICK; batch++) {
  res = await fetchWithTimeout(`${url}/api/v1/spaces/${id}/mutations?limit=${BATCH}`, …);
  if (res.status === 404 || res.status === 403 || !res.ok) return;  // servidor anterior al ledger
  { mutations, hasMore } = await res.json();
  if (mutations.length === 0) return;

  summary = applyIncomingMutations(db, mutations);
  recordServerInbox(summary.entries, { spaceId: config.spaceId });
  if (summary.cursor > 0) await fetchWithTimeout(`${endpoint}/ack`, { method: 'POST', … });
  if (summary.applied + summary.deleted > 0) markVaultDirty(config.vaultId);
  broadcastInboxChanged();

  if (summary.refused.length > 0) break;      // el cursor no avanzó: no des vueltas
  if (!hasMore) break;
  await new Promise((r) => setImmediate(r));  // ← la cesión
}
```

Sobre «que no entorpezca la interfaz», en concreto:

- **`?limit=25`.** El escritorio hoy no manda ni `?since=` ni `?limit=` e ignora el `hasMore` que
  el servidor devuelve (`serverSyncService.ts:350`); el servidor lo acota a 1..200
  (`server/lib/routes/api.mjs:453`). Sin límite, un teléfono que hubiera encolado 400 informes
  los aplicaría en una sola ráfaga síncrona sobre el hilo por el que pasa el IPC de todas las
  ventanas. Eso es la pelota de playa.
- **`setImmediate` entre lotes es la única cesión real.** better-sqlite3 es síncrono; un bucle
  sin un `await` verdadero nunca vuelve al bucle de eventos. Dilo en el comentario, porque
  parece ceremonia y no lo es.
- **Nunca un `await` dentro del callback de `db.transaction()`** — better-sqlite3 lo prohíbe, y
  `applyIncomingMutations` ya abre una transacción por mutación (líneas 91-140).
- **Acota el tick** (`MAX_BATCHES_PER_TICK = 8`, o sea 200 mutaciones). Lo que sobre espera 30 s.

**No añadas `?since=`.** `ledger.compact` borra el fichero cuando se vacía
(`server/lib/ledger.mjs:75-76`) y `nextSeq` lo recalcula leyéndolo (línea 34), así que **las
secuencias reinician en 1** en cuanto el ledger se vacía del todo. Todo lo que hay en el ledger
es, por definición, todo lo no confirmado. Por eso el código actual no lo manda: parece un
descuido y no lo es.

**No lo condiciones a `autoSync`.** `autoSync` significa «publica automáticamente»; negarse a
*recibir* porque el usuario pausó la publicación saliente es otra promesa distinta. Escribe ese
razonamiento en el comentario o alguien lo «arreglará».

Ciclo de vida: su propio `setInterval(30_000)` con `.unref?.()` y un primer tick a los ~8 s
(desplazado del `FIRST_TICK_MS = 5_000` del publicador para que no coincidan en el arranque).
Arranca y para junto a `startNodusServerSync` / `stopNodusServerSync` (`electron/main.ts:664`,
`electron/ipc.ts:286`, `:330`, `:540`). Drena también una vez al cambiar de vault activo.

Y ya que estás: `rt.lastInbox` no lo lee nadie. Muévelo al sondeo y sácalo en
`NodusServerConnection` desde `connectionFrom` (`serverSyncService.ts:229-251`), pintado junto a
`lastError` en `src/views/Settings.tsx:1638-1643`. Ahora que hay una bandeja, significa algo.

## B5 · El botón «Bandeja» en la cabecera

**Icono.** No hay ninguno que sirva: `ICON_PATHS` (`src/components/ui.tsx:55-178`) tiene
`archive`, `bell`, `download`, `file`, y nada más cercano. Añade una entrada — solo los
elementos interiores, sin envoltorio `<svg>`, caja de 24×24 y trazo de 2 px, que es lo que
`Icon` supone:

```ts
inbox: '<polyline points="22 12 16 12 14 15 10 15 8 12 2 12"/><path d="M5.45 5.11 2 12v6a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-6l-3.45-6.89A2 2 0 0 0 16.76 4H7.24a2 2 0 0 0-1.79 1.11z"/>',
```

`ICON_NAMES` (línea 182) se deriva y lo recoge solo. **Ojo: `Icon` hace `if (!path) return null`
(línea 186)**, así que un nombre mal escrito es un botón invisible sin ningún error.

**Insignia — el patrón no existe todavía en la cabecera.** El hueco `trailing` de
`HoverLabelButton` (`ui.tsx:292`) vive dentro del span de la etiqueta, que es `max-w-0
opacity-0` hasta el hover, así que no sirve. El único precedente está en la ventana de Nodi:
`.nodi-node-badge` (`src/components/nodi/companion.css:78-93`) y el recorte `>9 → '9+'` de
`NodiCompanion.tsx:1186`. Envuelve la acción y posiciónala en absoluto:

```tsx
<span className="relative inline-flex">
  <HeaderAction icon="inbox" label={t('Bandeja')} title={t('Lo que ha llegado de otros dispositivos')}
                onClick={(e) => toggleInbox(e.currentTarget)} />
  {unreadInbox > 0 && <span className="header-action-badge">{unreadInbox > 9 ? '9+' : unreadInbox}</span>}
</span>
```

más una regla `.header-action-badge` en `src/index.css` copiada de `.nodi-node-badge` (`#e2494a`,
16 px, `border-radius: 999px`, `box-shadow: 0 0 0 2px <fondo de la cabecera>`, `top:-2px;
right:-2px`) y su variante `.light`, como `companion.css:777`.

**Para no romper los tests de la cabecera:**
1. El botón va **dentro** de `<div ref={setHeaderActionsEl} data-testid="header-actions">`
   (`src/App.tsx:1127-1214`), para que lo mida el `ResizeObserver` de las líneas 804-826 y
   `placeHeaderBadge` mantenga la insignia del vault despejada. Una insignia fuera de esa caja es
   exactamente lo que la geometría no ve.
2. No toques el marcado de la insignia del vault: `scripts/test-header-layout.mjs` casa tres
   expresiones regulares contra `aria-expanded={Boolean(vaultAnchor)}`,
   `className="header-vault-badge ` y dos reglas CSS de `.light .app-titlebar
   button.header-vault-badge[aria-expanded='true']`.
3. Tu clase **no** puede llamarse `header-vault-badge` (de ahí `header-action-badge`).
4. La barra no tiene `overflow: hidden` hoy; no se lo pongas, o recortará la insignia.

El test de verdad es `scripts/e2e-smoke.mjs:795-860`, que mide el DOM vivo y exige 12 px de
holgura a cada lado de la insignia del vault. Un botón más de ~36 px a 1440 px deja la banda en
unos 880 px contra una insignia de ~140 px: sobra. Vuelve a pasarlo igualmente.

**El panel.** Hay dos precedentes: `ModalBackdrop` (`ui.tsx:351-395`) y el `VaultSwitcher`
anclado (`App.tsx:1216-1222`). **Usa el anclado.** Una bandeja es una lista que se ojea desde un
icono de la cabecera, no una tarea modal, y `ModalBackdrop` renderiza `fixed inset-0 grid
place-items-center`: un diálogo centrado para «qué ha llegado» pesa más de lo que el contenido
merece.

`src/components/ServerInbox.tsx`, props `{ anchorEl, onClose, entries, onMarkRead, onClearOne,
onClearAll, onOpenEntry }`. Copia de `VaultSwitcher` la colocación a partir del rect del
disparador, el cierre con Escape y el cierre al pulsar fuera. Marca el disparador con
`data-inbox-trigger` para que la lógica de «fuera» lo ignore, igual que hace `data-vault-trigger`
(líneas 1104 y 1130). Alterna con el idioma de `toggleVaults` (líneas 213-216).

Por entrada: nombre del espacio, `client_id` acortado, tiempo relativo desde `arrived_at`; el
`title` derivado (para un informe, su objetivo) o `tabla · clave`; un chip de resultado
(aplicado esmeralda / eliminado neutro / se conservó lo local ámbar / rechazado rojo con su
`reason`); un punto de no leído; y una ✕ por entrada. Al pie: «Marcar todo como leído» y «Vaciar
la bandeja». Pulsar una entrada `deep_research` pone `view = 'deepResearch'` y marca esa entrada
como leída. **Abrir el panel no marca nada** — el usuario pidió leído/no leído por entrada.

En `App.tsx`: `inboxAnchor`, `inbox: ServerInboxEntry[]`, y
`const unreadInbox = useMemo(() => inbox.reduce((n, e) => n + (e.read ? 0 : 1), 0), [inbox])` —
el mismo `reduce` que `NodiCompanion.tsx:142`. Carga al montar y suscríbete al canal push. **Sin
sondeo** (a diferencia de `Settings.tsx:310-322`, que pide el overview cada 3 s).

## B6 · Canales push

Con la forma exacta de `nodi:notifications:changed`: un notificador registrado en el proceso
principal (`electron/ipc.ts:369-373`), un ayudante de difusión con la forma de
`deepResearchLane.ts:37-41`, y un `on…Changed` en el preload que devuelva su propia baja
(`electron/preload/api.ts:91-95`).

1. **`nodusServer:inbox:changed`**, con `ServerInboxEntry[]`. Lo emite el sondeo tras cualquier
   lote que produzca entradas. Alimenta la insignia y el panel.
2. **`writing:saved:changed`**. Se emite cuando `summary.entries` contiene un `applied` o
   `deleted` con `table === 'writing_saved_drafts'`. **Esto es lo que hace que el informe
   aparezca sin remontar la vista.**

En `src/views/DeepResearchView.tsx`, junto al efecto de montaje de la línea 334:

```ts
useEffect(() => window.nodus.onWritingDraftsChanged(() => void refreshSavedDrafts()), [refreshSavedDrafts]);
```

`refreshSavedDrafts` es un `useCallback` con dependencias `[]` (línea 322), así que se registra
una sola vez. Ya filtra por `brief.kind === 'deep_research'` (línea 326), que es exactamente lo
que escribe `ReportDraft.row` en el teléfono.

Opcionalmente emite también `writing:saved:changed` desde `writing:saved:save` y
`writing:saved:delete` (`electron/ipc/academic.ts:1195-1209`), para que el canal signifique lo
que su nombre dice.

## B7 · i18n

**El español ES la clave** (`src/i18n.ts:47`). Todas las cadenas nuevas van a
`src/i18n.server.ts`, que ya contiene toda la superficie de ajustes de Nodus Server: añádelas al
`const EN` (líneas 1-71) y a los otros seis sub-objetos de `SERVER_TRANSLATIONS` (línea 75:
fr/de/pt/pt-BR/it/tr). Se derraman en `src/i18n.en.ts:29-46` y sus seis hermanos, así que no hay
que tocar ningún otro fichero.

| Español (la clave) | Inglés |
|---|---|
| `Bandeja` | `Inbox` |
| `Lo que ha llegado de otros dispositivos` | `What has arrived from other devices` |
| `Nada ha llegado todavía.` | `Nothing has arrived yet.` |
| `Aplicado` | `Applied` |
| `Eliminado` | `Deleted` |
| `Se conservó tu versión` | `Your version was kept` |
| `Rechazado` | `Refused` |
| `Informe de Deep Research` | `Deep Research report` |
| `Marcar todo como leído` | `Mark everything as read` |
| `Vaciar la bandeja` | `Empty the inbox` |
| `Quitar de la bandeja` | `Remove from the inbox` |
| `Abrir el informe` | `Open the report` |
| `Desde {device}` | `From {device}` |
| `Llegó el {when}` | `Arrived on {when}` |

Lo que el comprobador exige:
- **Solo literales.** `scripts/test-i18n-coverage.mjs` recorre `src/**/*.ts{,x}` y no ve una
  clave alcanzada por variable. `Settings.tsx:1518-1521` lo dice explícitamente y cuenta que así
  es como se enviaron una vez las etiquetas de la barra lateral sin traducir. Escribe los chips
  de resultado como una cadena de `if`/`else` de `t('Aplicado')` y no como
  `t(OUTCOME_LABEL[e.outcome])`. Si un mapa es inevitable, registra el fichero en
  `INDIRECT_KEY_SOURCES` (línea 114).
- **`tx`, nunca concatenación** — `tx('Desde {device}', { device })`. La línea 492 comprueba que
  los marcadores sobreviven a la traducción.
- **Una trampa que conviene nombrar:** `complete()` (`i18n.server.ts:73`) es `{...EN, ...values}`,
  así que todas las tablas contienen ya todas las claves inglesas y el test de «conjuntos de
  claves idénticos» (línea 482) pasa **aunque no traduzcas nada**. Una traducción olvidada se
  publica en inglés sin que nada chille. Tradúcelas las siete a mano.
- Si sacas a la interfaz una cadena de error del proceso principal, es prosa española y la línea
  560 comprueba que los errores españoles de Electron no se filtren a una interfaz que no lo es.
  O la metes en las tablas para que `tr()` la encuentre, o no la enseñas.

## B8 · Opcional, pero la parte del servidor es una línea

Expón el cursor para que el teléfono pueda llegar algún día a un tercer estado, «entregado».
En `spacesFor` (`server/lib/routes/api.mjs:36-55`), dentro del objeto que devuelve:

```js
mutationCursor: Number(space.mutationCursor || 0),
```

Llega a `/me` (línea 635) y a `/auth/login` (línea 103), ambos legibles por un teléfono con rol
`read`. `space.mutationCursor` ya lo persiste `ackMutations` (línea 463). El teléfono guardaría
el `cursor` que le devolvió su propio `POST` (línea 446) y lo compararía.

**Si lo haces, arregla esto primero.** `ledger.compact` borra el fichero al vaciarse (líneas
75-76) y `nextSeq` recalcula desde él (34-36), así que **las secuencias reinician en 1** tras una
compactación completa, y un cursor guardado se leería como «entregado» para algo que nunca se
envió. La corrección también es una línea: sembrar `nextSeq` desde
`Math.max(maxSeqEnFichero, space.mutationCursor) + 1`. Conviene de todas formas.

## B9 · Tests

| Test | Qué hacer |
|---|---|
| `scripts/test-connected-vault-replica.mjs` (172, 185, 193, 258) | comprobar los `outcome` nuevos de `summary.entries`; añadir un caso de idempotencia alrededor de la repetición deliberada de la línea 185 |
| `scripts/verify-connected-vault-live.mjs:296` | igual |
| **nuevo** `scripts/test-server-inbox.mjs` | lo recoge `npm test` solo (`node --test scripts/test-*.mjs`). Migra una base temporal a v123, mete un lote mixto (aplicado / se conserva lo local / rechazado), registra, y comprueba el orden, `unreadServerInboxCount`, `markServerInboxRead(id)` frente a todas, limpiar una, limpiar todo, **y que volver a registrar el mismo id no resucita la entrada como no leída** |
| `scripts/test-i18n-coverage.mjs` | falla ante cualquier literal `t()` nuevo que falte en las siete tablas |
| `scripts/test-header-layout.mjs` | no puede romperse por un botón nuevo; no toques las tres expresiones de la insignia del vault |
| `scripts/e2e-smoke.mjs:795-860` | mide la cabecera viva; pásalo tras añadir el botón |
| `npm run build` | incluye `typecheck`; `PlatformApi` es el contrato del preload que impone el compilador |
| repetición de migración | `runMigrations` dos veces sobre la misma base: la v123 es `CREATE` puro, así que aplica la vía `isAlreadyAppliedError` |

## Prueba de extremo a extremo

1. Modo básico, vault activo, teléfono emparejado con rol que permita escribir.
2. Generar un informe en el móvil → **Enviar** → confirmar. Aparece en la bandeja de salida del
   teléfono con la barra del color del vault y el estado «En el servidor».
3. **Sin tocar nada en el escritorio**, esperar ≤ 30 s: sube la insignia de «Bandeja», la entrada
   dice «Aplicado», y el informe aparece en Deep Research **sin remontar la vista**.
4. Cerrar el escritorio, enviar un segundo informe, reabrirlo: llega en el primer sondeo.
5. Reenviar el mismo informe: el escritorio actualiza el que ya tenía en vez de duplicarlo. El
   teléfono reutiliza el id de fila, así que esto prueba la ruta `UPDATE` de `mutationInbox.ts`.
6. Marcar leído, limpiar una entrada, limpiar todo.
