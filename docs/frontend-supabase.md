# Conexión del frontend con Supabase

## Dónde está cada cosa

| Archivo | Qué hace |
|---|---|
| `core/supabase/supabase.config.ts` | URL del proyecto y **clave publicable**. |
| `core/supabase/supabase.service.ts` | Cliente único de Supabase. |
| `core/auth/auth.service.ts` | Sesión, perfil, registro, inicio y cierre de sesión. |
| `core/auth/auth.guards.ts` | `authGuard` (pide sesión) y `guestGuard` (ingreso/registro). |
| `core/content/content.service.ts` | Niveles, lecciones, artículos, flashcards y evaluaciones. Único punto que consulta la base de datos. |
| `core/content/text-blocks.ts` | Convierte el texto de lecciones y artículos en párrafos y listas. |
| `shared/components/game-embed` | Juego de Educaplay que solo se carga al pulsar «Jugar». |
| `shared/components/medal` | Medalla de un nivel (gris si no se ha ganado). |

Todas las rutas del archivo están en `claria-web/src/app/`.

## Sobre la clave

La clave `sb_publishable_…` es **pública por diseño**: va en el navegador y puede estar en el repositorio.
No da acceso por sí sola; lo que cada usuario puede leer o escribir lo deciden las políticas RLS
(ver [base-de-datos.md](base-de-datos.md)). La clave **secreta** (`service_role`) nunca debe ir en el
frontend ni en el repositorio.

## Rutas

| Ruta | Página | Sesión |
|---|---|---|
| `/ingresar`, `/registro` | Inicio de sesión y registro | Sin sesión |
| `/aviso-de-privacidad` | Aviso de privacidad (preliminar) | Cualquiera |
| `/inicio` | Bienvenida, avance y siguiente reto | Requerida |
| `/cursos` | Niveles del grupo de edad | Requerida |
| `/cursos/:nivel` | Lecciones del nivel y acceso a su evaluación | Requerida |
| `/cursos/:nivel/leccion/:codigo` | Lección (texto, juego, fuente, artículo) | Requerida |
| `/evaluaciones`, `/evaluaciones/:nivel` | Evaluaciones finales | Requerida |
| `/flashcards`, `/articulos`, `/logros` | Recursos y medallas | Requerida |
| `/tokenizador`, `/detector` | Herramientas | Requerida |

## Rendimiento

- Cada página se carga bajo demanda (lazy loading). El paquete inicial pesa ~133 KB comprimido;
  el cliente de Supabase aporta ~70 KB.
- Los juegos de Educaplay (varios MB) no se descargan hasta que el estudiante pulsa «Jugar».
- Las medallas pasaron de PNG de ~1.5 MB a WebP de ~15 KB.

## Configuración pendiente en Supabase (panel web)

- **Authentication → URL Configuration**: agregar la URL donde se publique la app (y
  `http://localhost:4200` para desarrollo) en *Site URL* / *Redirect URLs*, para que el enlace del
  correo de confirmación regrese a la app.
- **Authentication → Emails**: el servidor de correo incluido en Supabase solo envía unos pocos
  correos por hora; para uso real con estudiantes conviene configurar un SMTP propio.
