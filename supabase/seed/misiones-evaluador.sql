-- =============================================================================
-- ClarIA 2.0 · Misiones del Evaluador de IA (BORRADOR para aprobación del equipo)
-- Se cargan con: SQL Editor de Supabase → pegar y ejecutar. Es idempotente:
-- no duplica misiones con el mismo título.
-- Las misiones con lesson_code son obligatorias para completar esa lección.
-- =============================================================================

with missions (age_group, lesson_code, sort_order, title, goal) as (values
  -- 8 a 11 años (rúbrica básica)
  ('8-11', null, 1, 'El misterio de los delfines',
   'Pide a la IA que te explique cómo duermen los delfines. Di quién eres, pídele que use palabras sencillas y pocas ideas, y escribe un ejemplo de cómo te gustaría la respuesta.'),
  ('8-11', null, 2, 'Repaso sin copiar',
   'Pide a la IA 5 preguntas para practicar sobre el ciclo del agua para tu examen, sin que te dé las respuestas. Cuenta para qué las necesitas y cómo las quieres.'),

  -- 12 a 14 años (rúbrica básica)
  ('12-14', '5.4', 1, 'La exposición de historia',
   'Escribe un prompt con los 5 ingredientes (rol, contexto, tarea, formato y ejemplo) para preparar una exposición de 5 minutos sobre las causas de la Revolución Mexicana para tus compañeros de 13 años.'),
  ('12-14', null, 2, 'Ciencia con analogías',
   'Pide a la IA que te explique la fotosíntesis con una analogía de la vida diaria para estudiar para tu examen de biología, organizada en una tabla de pasos.'),

  -- 15 a 17 años (rúbrica avanzada)
  ('15-17', '7.1', 1, 'Tutor socrático',
   'Configura a la IA como tutor socrático de física para entender las leyes de Newton: que no te dé la respuesta directa, que te guíe con preguntas, con restricciones claras y un ejemplo del tipo de pregunta que esperas.'),
  ('15-17', null, 2, 'Esquema de ensayo con fuentes',
   'Pide ayuda para el esquema (no el texto) de un ensayo argumentativo sobre la IA y el empleo: que primero te haga preguntas, que no invente datos y que te sugiera qué tipo de fuentes consultar.'),

  -- 18 años o más (rúbrica avanzada)
  ('18+', null, 1, 'Correo para prácticas profesionales',
   'Pide a la IA que revise y mejore el borrador de tu correo para solicitar prácticas profesionales: da contexto de la empresa y de tu perfil, indica el tono, la extensión máxima y un ejemplo de saludo.'),
  ('18+', null, 2, 'Análisis de datos con supuestos',
   'Pide a la IA que te guíe paso a paso para analizar una tabla de ventas mensuales de un pequeño negocio: que explique su razonamiento, que señale los supuestos y que no invente cifras.')
)
insert into public.scenarios (title, goal, is_published, age_group_id, lesson_id, passing_score, sort_order)
select m.title, m.goal, true,
       (select id from public.age_groups where code = m.age_group),
       (select id from public.lessons where code = m.lesson_code),
       70, m.sort_order
from missions m
where not exists (select 1 from public.scenarios s where s.title = m.title);
