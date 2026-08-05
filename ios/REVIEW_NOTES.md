# Notes for the App Store reviewer

Nodus is a client for a Nodus Server, which is software people run themselves. A reviewer has
no server, no account and no vault, so the app carries a corpus of its own and says so on its
first screen. What follows is the text to paste into **App Store Connect → App Review
Information → Notes**. Keep it to those two paragraphs; anything longer stops being read.

Regenerate the corpus with `node ios/scripts/make-demo-snapshot.mjs` whenever the vault schema
moves. It builds one snapshot per interface language from public-domain works only — no real
vault is ever read — and `ios/NodusTests/DemoSpaceTests.swift` fails the build if the binary
ships without them.

---

## English

> This app is a reader for a Nodus Server, a self-hosted research server. You do not need one to
> review the app, and you do not need an account. On the first screen, under the blue "Add a
> server" button, there is a second button: **"See an example vault"**. Tap it. It opens a small
> read-only corpus that is compiled into the app itself — ten public-domain works of
> nineteenth-century political thought, with the ideas, themes, quotations, debates and notes
> built on them. Everything in it is read from the device: no network connection is made at any
> point, and it works in aeroplane mode on a device that has never seen a server.
>
> Inside the example vault every part of the app is reachable: the sections on the home screen
> (Library, Ideas, Themes, Gaps, Authors), the record for any row, full-text search, the debates
> between contradicting ideas, and the argument map. Two features are deliberately shown but not
> functional there: **Chat** and **Deep Research** call an AI provider directly from the device
> with a key the user supplies under Settings → Providers, and the app never transmits that key
> to any Nodus server. Without a key those screens explain what would be needed rather than
> hiding themselves. Sign-in exists only for people who already run a Nodus Server of their own;
> no account is created by this app and none is required to see what it does.

## Español

> Esta app es un lector para Nodus Server, un servidor de investigación autoalojado. No hace
> falta tener uno para revisarla, ni una cuenta. En la primera pantalla, bajo el botón azul
> «Añadir un servidor», hay un segundo botón: **«Ver un vault de ejemplo»**. Púlselo. Abre un
> corpus breve de solo lectura compilado dentro de la propia app: diez obras de dominio público
> de pensamiento político del siglo XIX, con las ideas, los temas, las citas, los debates y las
> notas construidos sobre ellas. Todo se lee del dispositivo: no se abre ninguna conexión en
> ningún momento, y funciona en modo avión en un dispositivo que nunca ha visto un servidor.
>
> Dentro del vault de ejemplo se llega a todas las partes de la app: las secciones de la pantalla
> de inicio (Biblioteca, Ideas, Temas, Huecos, Autores), la ficha de cualquier registro, la
> búsqueda por texto, los debates entre ideas que se contradicen y el mapa de argumentos. Dos
> funciones se enseñan a propósito sin estar operativas allí: **Chat** e **Investigación
> profunda** llaman a un proveedor de IA directamente desde el dispositivo con una clave que
> aporta el usuario en Ajustes → Proveedores, y la app nunca envía esa clave a ningún servidor de
> Nodus. Sin clave, esas pantallas explican qué haría falta en lugar de esconderse. El inicio de
> sesión existe solo para quien ya tiene su propio Nodus Server; la app no crea ninguna cuenta y
> no hace falta ninguna para ver qué hace.
