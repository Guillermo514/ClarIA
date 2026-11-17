#!/usr/bin/env python3
"""
Genera supabase/seed/plan-curricular.json a partir de los documentos de PlanCurricular/.

Uso (desde la raíz del repositorio):
    python3 scripts/plan_curricular_a_json.py

Lee directamente los .docx (sin dependencias externas), valida que el plan esté
completo y escribe el JSON que consume la función public.load_curriculum().
Si algo no cuadra (lección sin artículo, pregunta sin respuesta, etc.) se detiene
sin escribir nada.
"""
import json
import re
import sys
import xml.etree.ElementTree as ET
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PLAN_DIR = ROOT / 'PlanCurricular'
OUT_FILE = ROOT / 'supabase' / 'seed' / 'plan-curricular.json'
PASSING_SCORE = 70
# Iconos disponibles en claria-web/public/assets/medals (niveles sin icono quedan en null).
MEDAL_ICONS = {n: f'assets/medals/nivel-{n:02d}.webp' for n in range(1, 9)}
AGE_GROUP_NAMES = {'8-11': '8 a 11 años', '12-14': '12 a 14 años', '15-17': '15 a 17 años', '18+': '18 años o más'}

# --- Lectura de .docx ------------------------------------------------------
W='{http://schemas.openxmlformats.org/wordprocessingml/2006/main}'
R='{http://schemas.openxmlformats.org/officeDocument/2006/relationships}'
def docx_text(path):
    z=zipfile.ZipFile(path)
    rels={}
    try:
        for r in ET.fromstring(z.read('word/_rels/document.xml.rels')):
            rels[r.get('Id')]=r.get('Target')
    except KeyError: pass
    body=ET.fromstring(z.read('word/document.xml')).find(W+'body')
    out=[]
    def para(p):
        txt=''
        for el in p.iter():
            if el.tag==W+'t': txt+=el.text or ''
            elif el.tag==W+'tab': txt+='\t'
            elif el.tag==W+'br': txt+='\n'
        links=[rels.get(h.get(R+'id')) for h in p.iter(W+'hyperlink') if h.get(R+'id')]
        # field-code hyperlinks
        for it in p.iter(W+'instrText'):
            m=re.search(r'HYPERLINK\s+"([^"]+)"', it.text or '')
            if m: links.append(m.group(1))
        sty=p.find(W+'pPr/'+W+'pStyle')
        s=sty.get(W+'val') if sty is not None else ''
        num=p.find(W+'pPr/'+W+'numPr')
        pre=('#['+s+'] ' if s.lower().startswith(('heading','ttulo','title')) else '')+('- ' if num is not None else '')
        return pre+txt+(' <'+' | '.join(l for l in links if l)+'>' if links else '')
    for el in body:
        if el.tag==W+'p': out.append(para(el))
        elif el.tag==W+'tbl':
            for tr in el.iter(W+'tr'):
                cells=[' / '.join(para(p) for p in tc.iter(W+'p')).strip() for tc in tr.findall(W+'tc')]
                out.append('| '+' | '.join(cells)+' |')
    return '\n'.join(l for l in out if l.strip())


DOCS = {
    name: docx_text(PLAN_DIR / f'{name}.docx').splitlines()
    for name in ('Niveles de estudio', 'Artículos para las lecciones de ClarIA', 'Flashcards', 'Evaluaciones')
}
read = lambda name: DOCS[name]

# --- Interpretación de los documentos --------------------------------------

AGE = re.compile(r'^(\d+)\s*(?:a\s*(\d+))?\s*\+?\s*años', re.I)
LEVEL = re.compile(r'^Nivel (\d+): [“"](.+?)[”"]')
LESSON = re.compile(r'^Lección (\d+)\.(\d+): (.+?)\s*(?:\((\d+) min\))?\s*$')
LINK = re.compile(r'^(.*?)\s*<([^>]+)>\s*$')

levels, groups = [], []
cur_group = cur_level = cur_lesson = None
for raw in read('Niveles de estudio'):
    line = raw.strip()
    if not line or line in ('Lecciones:', 'Niveles de estudio (Cursos)'):
        continue
    m = AGE.match(line)
    if m and len(line) < 20:
        lo, hi = int(m[1]), (int(m[2]) if m[2] else None)
        cur_group = {'code': f'{lo}-{hi}' if hi else f'{lo}+', 'min_age': lo, 'max_age': hi}
        groups.append(cur_group); continue
    if (m := LEVEL.match(line)):
        cur_level = {'number': int(m[1]), 'title': m[2].strip(), 'group': cur_group['code'],
                     'objective': '', 'medal': None, 'lessons': []}
        levels.append(cur_level); cur_lesson = None; continue
    if line.startswith('Objetivo:') and cur_lesson is None:
        cur_level['objective'] = line.split(':', 1)[1].strip(); continue
    if line.startswith('Medalla:'):
        name = line.split(':', 1)[1].strip().rstrip('.')
        cur_level['medal'] = re.sub(r'\s+y certificado$', '', name, flags=re.I); cur_lesson = None; continue
    if (m := LESSON.match(line)):
        cur_lesson = {'code': f'{m[1]}.{m[2]}', 'sort': int(m[2]), 'title': m[3].strip(),
                      'duration': int(m[4]) if m[4] else None, 'paragraphs': [], 'source': None, 'games': []}
        cur_level['lessons'].append(cur_lesson); continue
    if cur_lesson is None:
        raise SystemExit(f'Línea sin lección: {line[:80]}')
    body = line[2:].strip() if line.startswith('- ') else line
    if body.startswith('Fuente confiable:'):
        m = LINK.match(body.split(':', 1)[1].strip())
        cur_lesson['source'] = {'citation': m[1].strip(), 'url': m[2].strip()}; continue
    if body.startswith('Dinámica:'):
        src = re.search(r'src="([^"]+)"', body)
        cur_lesson['games'].append(src[1]); continue
    cur_lesson['paragraphs'].append(('- ' if line.startswith('- ') else '') + body)

# --- Artículos -----------------------------------------------------------
articles, cur, key = {}, None, None
FIELDS = {'Título del artículo': 'title', 'Fecha de publicación': 'published', 'Autor': 'author',
          'Resumen de la información': 'summary', 'Información completa': 'body', 'URL': 'url'}
for raw in read('Artículos para las lecciones de ClarIA'):
    line = raw.strip()
    if not line or LEVEL.match(line) or line.startswith(('Artículos para', 'BLOQUE')):
        continue
    if (m := LESSON.match(line)):
        cur = {'lesson': f'{m[1]}.{m[2]}', 'body': []}; articles[cur['lesson']] = cur; key = None; continue
    body = line[2:].strip() if line.startswith('- ') else line
    k = body.split(':', 1)[0].strip()
    if k in FIELDS and ':' in body:
        key = FIELDS[k]; val = body.split(':', 1)[1].strip()
        if key == 'body': cur['body'].append(val)
        elif key != 'lesson': cur[key] = val
    elif k == 'Lección':
        continue
    elif key == 'body':
        cur['body'].append(('- ' if line.startswith('- ') else '') + body)
    else:
        raise SystemExit(f'Artículo {cur and cur["lesson"]}: línea inesperada {line[:80]}')

# --- Flashcards ----------------------------------------------------------
cards, cur = [], None
for raw in read('Flashcards'):
    line = raw.strip()
    if re.match(r'^Flashcard \d+$', line):
        cur = {'n': int(line.split()[1])}; cards.append(cur)
    elif line.startswith('- Pregunta:'): cur['front'] = line.split(':', 1)[1].strip()
    elif line.startswith('- Respuesta:'): cur['back'] = line.split(':', 1)[1].strip()
    elif line and line != 'Flashcards':
        cur['back'] += ' ' + line  # respuesta en varias líneas

# --- Evaluaciones --------------------------------------------------------
quizzes, q = [], None
for raw in read('Evaluaciones'):
    line = raw.strip()
    if (m := re.match(r'^Evaluación Nivel (\d+)', line)):
        quiz = {'level': int(m[1]), 'questions': []}; quizzes.append(quiz); continue
    if (m := re.match(r'^(\d+)\.\s+(.+)$', line)):
        q = {'n': int(m[1]), 'statement': m[2], 'options': [], 'answer': None}; quiz['questions'].append(q); continue
    if (m := re.match(r'^- ([A-D])\)\s*(.+)$', line)):
        q['options'].append({'letter': m[1], 'text': m[2]}); continue
    if (m := re.match(r'^- Respuesta correcta:\s*([A-D])', line)):
        q['answer'] = m[1]; continue
    if line and line != 'Evaluaciones':
        raise SystemExit(f'Evaluación: línea inesperada {line[:80]}')


# --- Validación ------------------------------------------------------------
errs = []
warnings = []
codes = [l['code'] for lv in levels for l in lv['lessons']]
print('grupos', [(g['code'], [lv['number'] for lv in levels if lv['group'] == g['code']]) for g in groups])
print('niveles', len(levels), 'lecciones', len(codes), 'juegos', sum(len(l['games']) for lv in levels for l in lv['lessons']))
for lv in levels:
    if not lv['medal']: errs.append(f'nivel {lv["number"]} sin medalla')
    for l in lv['lessons']:
        if not l['duration']: warnings.append(f'{l["code"]} sin duración (se guarda vacía)')
        if not l['source']: errs.append(f'{l["code"]} sin fuente')
        if len(l['paragraphs']) < 2: errs.append(f'{l["code"]} contenido corto')
print('artículos', len(articles), 'faltan', sorted(set(codes) - set(articles)), 'sobran', sorted(set(articles) - set(codes)))
for a in articles.values():
    for f in ('title', 'author', 'summary', 'url', 'published'):
        if not a.get(f): errs.append(f'artículo {a["lesson"]} sin {f}')
    if not a['body']: errs.append(f'artículo {a["lesson"]} sin cuerpo')
print('flashcards', len(cards), 'numeración ok', [c['n'] for c in cards] == list(range(1, len(cards) + 1)))
for c in cards:
    if not c.get('front') or not c.get('back'): errs.append(f'flashcard {c["n"]} incompleta')
print('evaluaciones', len(quizzes), [len(z['questions']) for z in quizzes])
for z in quizzes:
    for q in z['questions']:
        if [o['letter'] for o in q['options']] != list('ABCD') or not q['answer']:
            errs.append(f'evaluación {z["level"]} pregunta {q["n"]} mal formada')
print('ERRORES:', errs or 'ninguno')
print('AVISOS:', warnings or 'ninguno')

if errs:
    raise SystemExit('El plan tiene errores; no se generó el JSON.')

# --- Construcción del JSON para load_curriculum() ---------------------------
def clean_url(url):
    return url.split(' <')[0].strip()

def lesson_content(paragraphs):
    return '\n\n'.join(paragraphs)

if len(cards) != 2 * len(codes):
    raise SystemExit(f'Se esperaban 2 flashcards por lección ({2 * len(codes)}) y hay {len(cards)}.')
cards_by_lesson = {code: cards[2 * i:2 * i + 2] for i, code in enumerate(codes)}
quiz_by_level = {z['level']: z for z in quizzes}

payload = {
    'age_groups': [
        {'code': g['code'], 'name': AGE_GROUP_NAMES.get(g['code'], g['code']),
          'min_age': g['min_age'], 'max_age': g['max_age'], 'sort_order': i + 1}
        for i, g in enumerate(groups)
    ],
    'levels': [],
}
for lv in levels:
    group_levels = [x['number'] for x in levels if x['group'] == lv['group']]
    lessons_out = []
    for l in lv['lessons']:
        a = articles[l['code']]
        lessons_out.append({
            'code': l['code'], 'sort_order': l['sort'], 'title': l['title'],
            'duration_min': l['duration'], 'content': lesson_content(l['paragraphs']),
            'games': l['games'],
            'source': {'citation': l['source']['citation'], 'url': clean_url(l['source']['url'])},
            'article': {'title': a['title'], 'author': a['author'], 'published_label': a['published'],
                        'summary': a['summary'], 'body': '\n\n'.join(a['body'])},
            'flashcards': [{'front': c['front'], 'back': c['back']} for c in cards_by_lesson[l['code']]],
        })
    quiz = quiz_by_level[lv['number']]
    payload['levels'].append({
        'number': lv['number'], 'sort_order': group_levels.index(lv['number']) + 1,
        'age_group': lv['group'], 'title': lv['title'], 'objective': lv['objective'],
        'medal': {'name': lv['medal'], 'icon': MEDAL_ICONS.get(lv['number']),
                  'description': f'Completaste el Nivel {lv["number"]}: {lv["title"]}.'},
        'lessons': lessons_out,
        'quiz': {
            'title': f'Evaluación Nivel {lv["number"]}: {lv["title"]}',
            'passing_score': PASSING_SCORE,
            'questions': [
                {'statement': q['statement'],
                  'options': [{'text': o['text'], 'is_correct': o['letter'] == q['answer']} for o in q['options']]}
                for q in quiz['questions']
            ],
        },
    })

OUT_FILE.parent.mkdir(parents=True, exist_ok=True)
OUT_FILE.write_text(json.dumps(payload, ensure_ascii=False, indent=1) + '\n', encoding='utf-8')
print(f'JSON generado en {OUT_FILE.relative_to(ROOT)}')
