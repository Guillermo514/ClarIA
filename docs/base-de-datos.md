# Base de datos de ClarIA

Proyecto de Supabase: **ClarIA** (`pvkxvuvbpgcgakvpabok`, región us-east-2, PostgreSQL 17).

- Diagrama entidad-relación: [diagrama-er.md](diagrama-er.md) (se ve directo en GitHub) y
  [ClariaDB-v2.drawio](ClariaDB-v2.drawio) (editable en diagrams.net). En verde, lo que se
  agregó respecto al diagrama original `ClariaDB.drawio(1).xml`.
- Migraciones: [`supabase/migrations/`](../supabase/migrations).
- Contenido del Plan Curricular: [`supabase/seed/plan-curricular.json`](../supabase/seed/plan-curricular.json).

## Contenido cargado

| Elemento | Cantidad | Origen en `PlanCurricular/` |
|---|---|---|
| Grupos de edad | 4 (8-11, 12-14, 15-17, 18+) | Niveles de estudio |
| Niveles (`courses`) | 12 (3 por grupo de edad) | Niveles de estudio |
| Lecciones | 57 | Niveles de estudio |
| Juegos (`lesson_activities`) | 5 (Educaplay, lecciones 1.1, 1.2, 1.3, 2.1 y 2.2) | Niveles de estudio |
| Artículos y fuentes | 57 y 57 (uno por lección) | Artículos para las lecciones |
| Flashcards | 114 (2 por lección, en el orden del documento) | Flashcards |
| Evaluaciones | 12 (una por nivel, 5 preguntas con 4 opciones) | Evaluaciones |
| Medallas (`achievements`) | 12 (una por nivel) | Niveles de estudio |

## Cambios respecto al diagrama original

El diagrama original cubría casi todo; estas son las ampliaciones para el Plan Curricular:

| Cambio | Motivo |
|---|---|
| Tabla nueva `age_groups` y `courses.age_group_id` | El plan organiza los niveles por edad (8-11, 12-14, 15-17, 18+). Sustituye a `courses.level` (texto). |
| `courses.level_number`, `courses.objective` | Número de nivel (1-12) y su objetivo. `objective` sustituye a `description`. |
| `lessons.code`, `lessons.content` | Clave del plan ("1.1") y el texto de la lección, que no tenía dónde guardarse. |
| Tabla nueva `lesson_activities` | Juegos de Educaplay por lección. Solo acepta URLs `https://es.educaplay.com/juego/...`. |
| `articles.summary`, `articles.published_label` | Resumen y fecha de publicación (texto libre, p. ej. "2023 (Actualizado…)"). |
| `achievements.course_id`, `sort_order` | Relaciona cada medalla con su nivel. Sin certificados: las medallas son las insignias. |
| `quizzes.passing_score` (70), `is_published` | Calificación mínima para aprobar y desbloquear el siguiente nivel. |
| `sort_order` en opciones y flashcards | Orden estable para mostrarlas. |
| `created_at` / `updated_at` | En niveles, lecciones y perfiles (se actualizan solos con un trigger). |

Las tablas de ejercicios críticos, escenarios del evaluador de prompts, encuestas, huella ambiental y
auditoría están creadas tal como en el diagrama, listas para cuando se definan sus datos.

## Validaciones

- Todos los textos tienen límites de longitud y no pueden quedar vacíos (`check`).
- Catálogos cerrados con `check`: roles, tipo de lección, tipo de pregunta, estado del progreso, etc.
- Claves únicas naturales: un nivel por número, una lección por código, una evaluación final por nivel,
  una fuente por URL, posiciones (`sort_order`) únicas dentro de su padre.
- URLs válidas (`https://...`); juegos solo de Educaplay; iconos solo de `assets/`.
- Coherencia: progreso `completed` ⇔ `completed_at` con fecha; un quiz es de lección **o** de nivel,
  nunca ambos; rangos de puntajes de 0 a 100; cajas de repaso de 1 a 5.
- Registro: la persona debe tener **8 años o más** y aceptar el aviso de privacidad vigente; si no, la
  cuenta no se crea.
- Al cargar el plan, cada pregunta debe tener **exactamente una** respuesta correcta.

## Seguridad (RLS)

Todas las tablas tienen Row Level Security.

- **Contenido publicado** (niveles, lecciones, juegos, artículos, flashcards, preguntas, medallas):
  lectura pública. Solo un `admin` puede crearlo, editarlo o borrarlo.
- **Respuestas correctas**: `question_options.is_correct` no es legible desde la API (permiso por
  columna). La calificación se hace en el servidor con `submit_quiz()`.
- **Datos de cada estudiante** (perfil, progreso, intentos, repasos, medallas): solo los ve su dueño.
  Docentes y administradores pueden ver perfiles.
- **Intentos y medallas** no se pueden insertar desde el navegador; solo `submit_quiz()` los crea.
- **Perfil**: el estudiante solo puede cambiar su nombre, institución y nivel académico (no su rol).
- **Auditoría**: cada cambio al contenido queda en `audit_logs` / `audit_log_changes` (solo admin).

El asesor de Supabase marca como aviso que algunas funciones `SECURITY DEFINER` se pueden llamar desde
la API. Es intencional: las de apoyo a RLS solo responden sí/no sobre el usuario actual, y
`load_curriculum` verifica que quien la llama sea admin.

## Avance por niveles

- Cada estudiante ve los 3 niveles de su grupo de edad, calculado con su fecha de nacimiento cada vez
  (al cumplir años pasa al grupo siguiente).
- El primer nivel del grupo está abierto; los demás se desbloquean al **aprobar con 70 % o más** la
  evaluación final del nivel anterior. Al aprobar se otorga la medalla del nivel.
- Docentes y administradores ven los 12 niveles desbloqueados.

## Funciones para la aplicación (RPC)

| Función | Uso |
|---|---|
| `get_my_levels()` | Niveles del usuario con desbloqueo, progreso, mejor puntaje y medalla. |
| `submit_quiz(quiz_id, answers)` | Califica, guarda el intento y otorga la medalla. `answers`: `[{"question_id", "option_ids": [...]}]`. |
| `load_curriculum(payload)` | Carga o actualiza el Plan Curricular (solo admin). |

## Tareas frecuentes

### Actualizar el contenido cuando cambie el Plan Curricular

1. Edita los `.docx` de `PlanCurricular/`.
2. Genera el JSON (valida que no falte nada; si hay errores, no escribe el archivo):
   ```bash
   python3 scripts/plan_curricular_a_json.py
   ```
3. Cárgalo en el SQL Editor de Supabase. La carga es idempotente: actualiza lo existente y agrega lo nuevo.
   ```sql
   select public._load_curriculum('<contenido de supabase/seed/plan-curricular.json>'::jsonb);
   ```

### Convertir una cuenta en administrador o docente

La persona se registra en la app y después, en el SQL Editor:

```sql
update public.profiles
set role_id = (select id from public.roles where name = 'admin')  -- o 'teacher'
where id = (select id from auth.users where email = 'correo@ejemplo.com');
```

### Regenerar los diagramas

1. Ejecuta [`supabase/consultas/esquema-para-diagramas.sql`](../supabase/consultas/esquema-para-diagramas.sql)
   en el SQL Editor y copia el resultado a `supabase/esquema.txt` (secciones `# tablas` y `# relaciones`).
2. Genera los diagramas:
   ```bash
   python3 scripts/esquema_a_diagramas.py
   ```

## Pendientes del plan

- **Lección 1.1** no tiene duración en el documento (se guardó vacía).
- **Medallas de los niveles 9 a 12** aún no tienen icono en `Iconos Medallas/`; la app muestra un
  icono genérico mientras tanto.
- **Consentimiento de padres o tutores** para menores: falta definirlo (hoy solo se acepta el aviso de
  privacidad al registrarse). El texto del aviso en `/aviso-de-privacidad` es preliminar.
- Valores de **huella ambiental**, **escenarios del evaluador de prompts**, **ejercicios críticos** y
  **encuestas**: tablas listas, sin datos.
