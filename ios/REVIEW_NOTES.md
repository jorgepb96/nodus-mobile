# Notes for the App Store reviewer

Nodus 0.1.0 is a companion for Nodus Desktop. A reviewer can use the built-in example vault
without an account or a Mac connection. The following notes describe the current onboarding;
they are source notes, not evidence of an App Store submission or TestFlight approval.

Regenerate the corpus with `node ios/scripts/make-demo-snapshot.mjs` whenever the vault schema
moves. It builds one snapshot per interface language from public-domain works only — no real
vault is ever read — and `ios/NodusTests/DemoSpaceTests.swift` fails the build if the binary
ships without them.

---

## English

> Nodus is an iPhone/iPad companion for Nodus Desktop. No account or connected Mac is required
> to inspect the built-in example vault, available from the first screen. Its public-domain
> research corpus and reading data are bundled with the app and can be consulted offline.
> Connecting a personal workspace uses Desktop Settings → Mobile connection and a temporary
> QR, code or link over the same local network or VPN. Server/Cloud onboarding is hidden in
> this beta; no Nodus account is created.
>
> AI execution modes are explicit. Live mode uses the connected Mac's models and credentials;
> autonomous mode uses the provider configured on the mobile device. Provider credentials stay
> on their owning device. Without an available Mac or configured mobile provider, generation
> explains the missing connection/configuration. Reading and selected temporary Scriptor
> downloads work offline. Pending authored notes, ideas and structured edits synchronize when
> the Mac returns, with explicit revision-conflict choices. Extraction/indexing remain Desktop
> operations. Browser, Radar, Compass, Focus and other unimplemented tools show coming soon.

## Español

> Nodus es una aplicación companion para Nodus Desktop en iPhone y iPad. No hace falta una
> cuenta ni un Mac conectado para consultar el vault de ejemplo de la primera pantalla. Su
> corpus de dominio público y sus datos de lectura están incluidos en la app y funcionan sin
> conexión. Para vincular un workspace personal, abra Ajustes → Conexión móvil en Desktop y
> utilice el QR, código o enlace temporal desde la misma red local o VPN. La conexión mediante
> Server/Cloud está oculta en esta beta; la app no crea una cuenta de Nodus.
>
> Los modos de IA son explícitos. Live utiliza los modelos y credenciales del Mac conectado;
> autónomo utiliza el proveedor configurado en el móvil. Las credenciales permanecen en su
> dispositivo. Sin un Mac disponible o un proveedor móvil configurado, la generación explica
> qué falta. La lectura y las descargas temporales seleccionadas de Scriptor funcionan sin
> conexión. Las notas, ideas y ediciones estructuradas pendientes se sincronizan al volver el
> Mac, con una elección explícita ante conflictos de revisión. La extracción e indexación se
> realizan en Desktop. Browser, Radar, Compass, Focus y otras herramientas pendientes muestran
> «Próximamente».
