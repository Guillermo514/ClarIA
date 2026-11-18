-- =============================================================================
-- ClarIA 2.0 · Misiones del Evaluador de IA y sus requisitos
--
-- Cómo editar:
--   * Misiones: título, objetivo, grupo de edad y, si es obligatoria, la lección.
--   * Requisitos: qué debe mencionar cada campo (rol, contexto, tarea, formato,
--     ejemplo, tecnicas). `terms` son sinónimos: basta con que aparezca uno.
--     No hace falta escribir acentos ni mayúsculas (se normalizan solos).
--     El campo `tecnicas` solo existe para 15-17 y 18+.
-- Cómo cargar: SQL Editor de Supabase → pegar y ejecutar. Es idempotente:
-- actualiza las misiones por título y reemplaza sus requisitos.
-- =============================================================================

-- --- Misiones ----------------------------------------------------------------

with missions (age_group, lesson_code, sort_order, title, goal) as (values
  ('8-11', null, 1, 'El misterio de los delfines',
   'Pide a la IA que te explique cómo duermen los delfines. Di quién eres, pídele palabras sencillas y pocas ideas, y escribe un ejemplo de cómo te gustaría la respuesta.'),
  ('8-11', null, 2, 'Repaso sin copiar',
   'Pide a la IA 5 preguntas para practicar sobre el ciclo del agua para tu examen, sin que te dé las respuestas.'),
  ('12-14', '5.4', 1, 'La exposición de historia',
   'Prepara un prompt con los 5 ingredientes para una exposición de 5 minutos sobre las causas de la Revolución Mexicana, dirigida a tus compañeros de 13 años.'),
  ('12-14', null, 2, 'Ciencia con analogías',
   'Pide a la IA que te explique la fotosíntesis con una analogía de la vida diaria para estudiar para tu examen de biología, organizada en una tabla de pasos.'),
  ('15-17', '7.1', 1, 'Tutor socrático',
   'Configura a la IA como tutor socrático de física para entender las leyes de Newton: que no te dé la respuesta directa y que te guíe con preguntas.'),
  ('15-17', null, 2, 'Esquema de ensayo con fuentes',
   'Pide ayuda para el esquema (no el texto) de un ensayo argumentativo sobre la IA y el empleo: que primero te haga preguntas, que no invente datos y que sugiera qué tipo de fuentes consultar.'),
  ('18+', null, 1, 'Correo para prácticas profesionales',
   'Pide a la IA que revise y mejore el borrador de tu correo para solicitar prácticas profesionales: da contexto de la empresa y de tu perfil, el tono, la extensión máxima y un ejemplo de saludo.'),
  ('18+', null, 2, 'Análisis de datos con supuestos',
   'Pide a la IA que te guíe paso a paso para analizar una tabla de ventas mensuales de un pequeño negocio: que explique su razonamiento, que señale los supuestos y que no invente cifras.')
),
updated as (
  update public.scenarios s
     set goal = m.goal,
         age_group_id = (select id from public.age_groups where code = m.age_group),
         lesson_id = (select id from public.lessons where code = m.lesson_code),
         sort_order = m.sort_order,
         is_published = true
    from missions m
   where s.title = m.title
  returning s.title
)
insert into public.scenarios (title, goal, is_published, age_group_id, lesson_id, passing_score, sort_order)
select m.title, m.goal, true,
       (select id from public.age_groups where code = m.age_group),
       (select id from public.lessons where code = m.lesson_code),
       70, m.sort_order
from missions m
where not exists (select 1 from public.scenarios s where s.title = m.title);

-- --- Requisitos por campo ----------------------------------------------------

-- Se reemplazan los requisitos de las misiones de este archivo.
delete from public.scenario_requirements sr
using public.scenarios s
where sr.scenario_id = s.id
  and s.title in ('El misterio de los delfines', 'Repaso sin copiar', 'La exposición de historia',
                  'Ciencia con analogías', 'Tutor socrático', 'Esquema de ensayo con fuentes',
                  'Correo para prácticas profesionales', 'Análisis de datos con supuestos');

with reqs (mission, sort_order, field, label, terms) as (values
  -- El misterio de los delfines (8-11)
  ('El misterio de los delfines', 1, 'contexto', 'Di quién eres (tu edad o tu grado)',
   array['años', 'grado', 'primaria', 'niño', 'niña', 'estudiante', 'alumno', 'alumna']),
  ('El misterio de los delfines', 2, 'tarea', 'Menciona a los delfines', array['delfin', 'delfines']),
  ('El misterio de los delfines', 3, 'tarea', 'Pregunta cómo duermen',
   array['duermen', 'dormir', 'duerme', 'sueño', 'descansan', 'descansar']),
  ('El misterio de los delfines', 4, 'formato', 'Pide palabras sencillas o pocas ideas',
   array['sencillo', 'sencillas', 'sencillos', 'facil', 'faciles', 'simple', 'simples', 'pocas', 'ideas', 'corto', 'corta', 'breve']),

  -- Repaso sin copiar (8-11)
  ('Repaso sin copiar', 1, 'contexto', 'Di que es para estudiar para tu examen',
   array['examen', 'prueba', 'estudiar', 'repasar', 'evaluacion']),
  ('Repaso sin copiar', 2, 'tarea', 'Pide preguntas para practicar',
   array['preguntas', 'pregunta', 'cuestionario', 'practicar', 'repasar']),
  ('Repaso sin copiar', 3, 'tarea', 'Menciona el ciclo del agua',
   array['ciclo del agua', 'evaporacion', 'condensacion', 'precipitacion']),
  ('Repaso sin copiar', 4, 'formato', 'Indica cuántas preguntas quieres', array['5', 'cinco']),
  ('Repaso sin copiar', 5, 'formato', 'Pide que no te dé las respuestas',
   array['sin respuestas', 'sin las respuestas', 'no me des', 'no des', 'sin darme', 'no me digas']),

  -- La exposición de historia (12-14, obligatoria en 5.4)
  ('La exposición de historia', 1, 'rol', 'Un experto en historia o un docente',
   array['historia', 'historiador', 'historiadora', 'profesor', 'profesora', 'maestro', 'maestra', 'docente']),
  ('La exposición de historia', 2, 'contexto', 'Menciona que es para una exposición',
   array['exposicion', 'presentacion', 'exponer', 'presentar']),
  ('La exposición de historia', 3, 'contexto', 'Di que tus compañeros tienen 13 años', array['13', 'trece']),
  ('La exposición de historia', 4, 'tarea', 'Pide las causas', array['causas', 'causa', 'motivos', 'origenes', 'razones', 'por que']),
  ('La exposición de historia', 5, 'tarea', 'Menciona la Revolución Mexicana', array['revolucion mexicana', 'revolucion']),
  ('La exposición de historia', 6, 'formato', 'Indica la duración de 5 minutos', array['5 minutos', 'cinco minutos']),
  ('La exposición de historia', 7, 'formato', 'Pide una tabla, lista o esquema',
   array['tabla', 'lista', 'columnas', 'puntos', 'esquema', 'vinetas']),

  -- Ciencia con analogías (12-14)
  ('Ciencia con analogías', 1, 'contexto', 'Di que es para tu examen de biología o ciencias',
   array['examen', 'biologia', 'ciencias', 'estudiar']),
  ('Ciencia con analogías', 2, 'tarea', 'Menciona la fotosíntesis', array['fotosintesis']),
  ('Ciencia con analogías', 3, 'tarea', 'Pide una analogía o comparación',
   array['analogia', 'comparacion', 'compara', 'como si', 'parecido', 'vida diaria', 'vida cotidiana']),
  ('Ciencia con analogías', 4, 'formato', 'Pide una tabla de pasos', array['tabla', 'pasos']),

  -- Tutor socrático (15-17, obligatoria en 7.1)
  ('Tutor socrático', 1, 'rol', 'Un tutor o profesor de física',
   array['tutor', 'tutora', 'profesor', 'profesora', 'docente', 'maestro', 'maestra', 'fisica', 'socratico']),
  ('Tutor socrático', 2, 'contexto', 'Di tu nivel escolar',
   array['preparatoria', 'prepa', 'bachillerato', 'semestre', 'estudiante']),
  ('Tutor socrático', 3, 'tarea', 'Menciona las leyes de Newton', array['newton']),
  ('Tutor socrático', 4, 'tecnicas', 'Que no te dé la respuesta directa',
   array['no me des la respuesta', 'sin darme la respuesta', 'no me digas la respuesta', 'no resuelvas', 'no des la respuesta', 'respuesta directa']),
  ('Tutor socrático', 5, 'tecnicas', 'Que te guíe con preguntas',
   array['preguntas', 'pregunta', 'preguntame', 'guiame', 'una pregunta a la vez']),

  -- Esquema de ensayo con fuentes (15-17)
  ('Esquema de ensayo con fuentes', 1, 'tarea', 'Pide un esquema, no el texto completo',
   array['esquema', 'estructura', 'indice', 'guion', 'bosquejo']),
  ('Esquema de ensayo con fuentes', 2, 'tarea', 'Tema: la IA y el empleo',
   array['empleo', 'empleos', 'trabajo', 'trabajos', 'laboral']),
  ('Esquema de ensayo con fuentes', 3, 'tecnicas', 'Que primero te haga preguntas',
   array['hazme preguntas', 'preguntame', 'antes de', 'primero', 'preguntas']),
  ('Esquema de ensayo con fuentes', 4, 'tecnicas', 'Que no invente datos',
   array['no inventes', 'sin inventar', 'no invente', 'datos reales', 'verificables', 'no inventar']),
  ('Esquema de ensayo con fuentes', 5, 'formato', 'Que sugiera tipos de fuentes',
   array['fuentes', 'referencias', 'bibliografia']),

  -- Correo para prácticas profesionales (18+)
  ('Correo para prácticas profesionales', 1, 'contexto', 'Da contexto de la empresa y de tu perfil',
   array['empresa', 'perfil', 'carrera', 'estudio', 'egresado', 'egresada', 'experiencia']),
  ('Correo para prácticas profesionales', 2, 'tarea', 'Pide revisar y mejorar tu borrador',
   array['revisa', 'mejora', 'corrige', 'borrador', 'mejorar', 'revisar']),
  ('Correo para prácticas profesionales', 3, 'formato', 'Indica el tono', array['tono', 'formal', 'profesional', 'cordial']),
  ('Correo para prácticas profesionales', 4, 'formato', 'Indica la extensión máxima',
   array['palabras', 'lineas', 'parrafos', 'breve', 'maximo', 'corto']),
  ('Correo para prácticas profesionales', 5, 'ejemplo', 'Incluye un ejemplo de saludo',
   array['estimado', 'estimada', 'estimados', 'saludo', 'buenos dias', 'buen dia', 'a quien corresponda']),

  -- Análisis de datos con supuestos (18+)
  ('Análisis de datos con supuestos', 1, 'contexto', 'Menciona el pequeño negocio', array['negocio', 'tienda', 'empresa', 'emprendimiento']),
  ('Análisis de datos con supuestos', 2, 'tarea', 'Pide analizar una tabla de ventas', array['ventas', 'venta']),
  ('Análisis de datos con supuestos', 3, 'tecnicas', 'Que razone paso a paso',
   array['paso a paso', 'razonamiento', 'razona', 'explica tu razonamiento']),
  ('Análisis de datos con supuestos', 4, 'tecnicas', 'Que señale los supuestos', array['supuestos', 'suposiciones', 'asume', 'asumes']),
  ('Análisis de datos con supuestos', 5, 'tecnicas', 'Que no invente cifras',
   array['no inventes', 'sin inventar', 'no invente', 'cifras reales', 'no inventar'])
)
insert into public.scenario_requirements (scenario_id, field, label, terms, sort_order)
select s.id, r.field, r.label, r.terms, r.sort_order
from reqs r
join public.scenarios s on s.title = r.mission;
