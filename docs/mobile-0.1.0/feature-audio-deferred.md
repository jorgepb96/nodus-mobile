# Audio en la beta móvil 0.1.0

La generación de narración, voz y audio queda pospuesta por decisión del usuario del 15 de octubre de 2026. No se elimina su implementación de Desktop ni se habilitan proveedores móviles para esta función. La IA autónoma tiene un control de disponibilidad independiente.

## Entradas y fronteras

- El bundle móvil sustituye `AudioPanel` por `src/mobileWeb/MobileAudio.tsx`: consulta pistas guardadas y abre el reproductor nativo. Muestra «Generar audio · Próximamente»; no carga motores TTS ni muestra regeneración. `StudyDictation` ya se presenta como Próximamente.
- `shared/mobileAudioBeta.ts` declara la capacidad tipada `audioGeneration: false`. El despacho común del host móvil rechaza preparación de segmentos, síntesis Hume y persistencia de una pista generada, además de los nombres de generación explícitos. No afecta al renderer Desktop normal.
- `MobileAudioBeta.swift` consume el gate central `BetaAIFeatures.audioGeneration = false` y aplica la misma denegación antes de despachar un mensaje WebKit, incluso si se omite el control JavaScript. El error conserva el código `mobile_audio_generation_deferred`.
- El registro privado móvil sólo ofrece `listAudioClips` para narraciones; no añade operaciones de generación.

## Consulta que se conserva

`listAudioClips`, `openSavedAudioClip`, las descargas verificadas de archivos privados, `SavedAudioPlayer` y las grabaciones/medios ya guardados o descargados conservan su comportamiento. Las restricciones de conexión, permiso o selección de copia existentes siguen vigentes. No se promete reproducir un archivo que nunca se descargó cuando el Mac está apagado.

## Validación

Contrato local focal de la política móvil: métodos de generación denegados y métodos de consulta/reproducción permitidos. No constituye aceptación nativa, prueba de proveedor ni autorización para generación de audio.

Evidencia: `artifacts/interface-2026-10-15/mobile-audio-beta-policy-02.log` (Desktop), 1 contrato PASS, 0 skips; parse focal de `MobileAudioBeta.swift` y `SharedDesktopSurface.swift` PASS. No se ejecutaron compilación Xcode ni simuladores.
