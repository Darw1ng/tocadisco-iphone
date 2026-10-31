# Toca Disco para iPhone

La versión para iPhone de la app de celular de Toca Disco. Hace lo mismo que la de Android
(`android-movil/` en el repo Rockola): abre `https://www.tocadisco.com.mx/app` dentro de la app,
sin barra de direcciones, y la web decide todo lo que se ve.

En iPhone no existe el APK. El equivalente es un **.ipa**, y no se instala pasándolo al
celular: se instala con **TestFlight** (la app de pruebas de Apple) o desde la **App Store**.
Por eso este repo compila la app en una Mac de GitHub Actions y la sube sola a TestFlight.

## Qué hace la app

Lo mismo que la de Android, adaptado a iPhone:

- **La página.** Un `WKWebView` abre `APP_URL` (`/app`: el personal cae en el control, el dueño
  en su panel y el admin en el admin). La sesión se queda guardada al cerrar y abrir la app.
- **La web la reconoce.** Agrega `TocaDiscoMovil/1.0` al user agent, igual que Android, así que
  la web ya se porta como app (`data-app`, deslizar para recargar) sin cambiarle nada.
- **Colores de las orillas.** La página llama a `window.TocaDiscoApp.barras(arriba, abajo, fondo)`
  (el mismo puente de Android) y la app pinta la franja de la isla/muesca y la de la barra de
  inicio, con íconos claros u oscuros según el color.
- **Arranque.** El logo sobre negro hasta que la primera página ya se pintó.
- **Sin conexión.** Pantalla propia con «Reintentar»; se reintenta sola cuando vuelve el internet.
  Si el servidor responde 5xx, «Toca Disco no responde».
- **Enlaces.** Lo de tocadisco.com.mx (con o sin www) y Stripe se quedan adentro; lo demás sale
  a Safari, Mail, Teléfono o WhatsApp.
- **Atrás.** Deslizar desde la orilla izquierda. No regresa al formulario de entrada con la sesión
  ya abierta ni al panel después de cerrarla.
- **Fotos.** Los campos de archivo abren la cámara o la fototeca de iOS.
- **Descargas.** Los reportes en CSV se bajan y se abre el menú de compartir (Guardar en Archivos,
  WhatsApp, correo…).
- Solo iPhone y solo vertical. Desde iOS 15. Identificador: `mx.tocadisco.movil`.

## Preparar Apple (una sola vez)

Se hace con la cuenta de Apple Developer que ya se pagó.

1. **Team ID.** En [developer.apple.com/account](https://developer.apple.com/account) →
   *Membership details* → *Team ID* (10 letras y números).
2. **Registrar el identificador.** [Identifiers](https://developer.apple.com/account/resources/identifiers/list)
   → **+** → *App IDs* → *App* → descripción «Toca Disco», *Bundle ID* explícito
   `mx.tocadisco.movil` → *Register*.
3. **Crear la app en App Store Connect.** [appstoreconnect.apple.com](https://appstoreconnect.apple.com)
   → *Apps* → **+** → *New App*: plataforma iOS, nombre «Toca Disco», idioma Español (México),
   Bundle ID `mx.tocadisco.movil`, SKU `tocadisco-ios`.
4. **Llave de la API.** App Store Connect → *Users and Access* → *Integrations* →
   *App Store Connect API* → *Team Keys* → **+**. Nombre «GitHub Actions», acceso **Admin**
   (hace falta para que la Mac de GitHub pueda crear el certificado de distribución sola).
   Descarga el archivo `AuthKey_XXXXXXXXXX.p8` (solo se puede bajar una vez) y anota el
   **Key ID** y el **Issuer ID** que aparecen en esa página.

## Poner los secretos en GitHub

En este repo: *Settings* → *Secrets and variables* → *Actions* → *New repository secret*:

| Secreto | Qué va |
| --- | --- |
| `APPLE_TEAM_ID` | El Team ID del paso 1 |
| `ASC_KEY_ID` | El Key ID de la llave |
| `ASC_ISSUER_ID` | El Issuer ID |
| `ASC_KEY_P8` | Todo el contenido del archivo `.p8`, abierto con el Bloc de notas, incluidas las líneas `-----BEGIN PRIVATE KEY-----` y `-----END PRIVATE KEY-----` |

Los secretos no se ven ni en los registros ni en el código, aunque el repo sea público.

## Compilar y subir

- Cada push a `main` compila. O en *Actions* → **iPhone** → *Run workflow* (ahí también se puede
  poner otra dirección para una instalación de pruebas).
- **Sin secretos:** compila y deja `TocaDisco-sin-firmar.ipa` en *Artifacts*. Sirve para revisar
  que compila o para instalarlo con Sideloadly/AltStore desde Windows con un Apple ID
  (esas instalaciones caducan a los 7 días).
- **Con secretos:** además firma la app y la sube a App Store Connect. El número de compilación
  es el número de la corrida, así que nunca se repite.

## Instalarla en los iPhone (TestFlight)

1. A los 5–30 minutos la compilación aparece en App Store Connect → la app → **TestFlight**.
   La primera vez pide contestar lo de cifrado: ya va respondido en la app (no usa cifrado propio).
2. *Internal Testing* → **+** → crea un grupo y agrega a las personas (deben estar en
   *Users and Access* de la cuenta; hasta 100). No necesita revisión de Apple.
3. Cada quien instala **TestFlight** desde la App Store, abre la invitación y toca *Instalar*.
   Las compilaciones nuevas les llegan como actualización.

Para gente fuera de la cuenta (por ejemplo clientes), *External Testing* permite hasta 10,000
con un enlace público, pero la primera compilación pasa por una revisión corta de Apple.

## Publicar en la App Store

Es un paso aparte: capturas de pantalla, descripción, política de privacidad, cuenta de
demostración para el revisor y la revisión de Apple. Apple a veces rechaza apps que solo
muestran una página web (regla 4.2); para la revisión conviene explicar que es la app de control
para clientes de Toca Disco y dar la cuenta de demostración. Para uso interno del equipo y de
clientes, TestFlight basta.

## Cambiar la dirección que abre

- `APP_URL` en `project.yml`, o
- el campo de *Run workflow*.

## Abrirla en una Mac

```bash
brew install xcodegen
xcodegen generate
open TocaDisco.xcodeproj
```

El proyecto de Xcode no se guarda en el repo: `project.yml` lo describe y XcodeGen lo genera.

## Notas

- El sufijo del user agent (`TocaDiscoMovil`) y el nombre del puente (`TocaDiscoApp`) deben
  coincidir con `MOBILE_APP_UA` y `MOBILE_APP_BRIDGE` en `src/lib/mobile-app.ts` de la web.
- El puente solo acepta colores `#rrggbb` y solo de páginas de Toca Disco.
- Los enlaces del correo de «Olvidé mi contraseña» se abren en Safari. Para que abran la app
  harían falta *Universal Links* (un archivo `apple-app-site-association` en la web y la
  capacidad *Associated Domains*); la app ya está lista para recibirlos.
