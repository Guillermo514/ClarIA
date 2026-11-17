#!/usr/bin/env python3
"""
Genera los diagramas de la base de datos a partir de supabase/esquema.txt:
  * docs/diagrama-er.md      -> diagrama Mermaid (GitHub lo dibuja solo)
  * docs/ClariaDB-v2.drawio  -> diagrama editable en draw.io / diagrams.net

supabase/esquema.txt se obtiene de la base de datos real con la consulta que
aparece en docs/base-de-datos.md («Regenerar los diagramas»).
Las tablas y columnas agregadas respecto al diagrama original se marcan en verde.
"""
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
SRC = ROOT / 'supabase' / 'esquema.txt'

# Agrupación por dominio (una columna del diagrama por grupo).
GROUPS = [
    ('Usuarios y privacidad', ['roles', 'age_groups', 'profiles', 'privacy_notice_versions', 'privacy_consents']),
    ('Niveles y lecciones', ['courses', 'lessons', 'lesson_activities', 'lesson_progress', 'sources', 'articles', 'article_sources']),
    ('Evaluaciones', ['quizzes', 'questions', 'question_options', 'quiz_attempts', 'quiz_answers', 'quiz_answer_options']),
    ('Flashcards y logros', ['flashcards', 'flashcard_reviews', 'achievements', 'achievement_rule_groups', 'achievement_rules', 'user_achievements']),
    ('Ejercicios y prompts', ['critical_exercises', 'critical_exercise_issues', 'exercise_attempts', 'selected_exercise_issues',
                              'scenarios', 'scenario_criteria', 'scenario_response_templates', 'prompt_attempts']),
    ('Encuestas', ['surveys', 'survey_questions', 'survey_options', 'survey_responses', 'survey_answers', 'survey_answer_options']),
    ('Huella ambiental y auditoría', ['eco_task_types', 'eco_factor_versions', 'eco_factor_sources', 'eco_estimates',
                                      'audit_entity_types', 'audit_logs', 'audit_log_changes']),
]
NEW_TABLES = {'age_groups', 'lesson_activities'}
NEW_COLUMNS = {
    'courses': {'age_group_id', 'level_number', 'objective', 'created_at', 'updated_at'},
    'lessons': {'code', 'content', 'created_at', 'updated_at'},
    'articles': {'summary', 'published_label'},
    'achievements': {'course_id', 'sort_order'},
    'quizzes': {'passing_score', 'is_published'},
    'question_options': {'sort_order'},
    'flashcards': {'sort_order'},
    'profiles': {'updated_at'},
    'quiz_answers': {'score_earned'},
}


def load():
    tables, fks = {}, []
    section = None
    for line in SRC.read_text(encoding='utf-8').splitlines():
        if line.startswith('# '):
            section = line[2:].strip()
            continue
        if not line.strip():
            continue
        if section == 'tablas':
            name, cols = line.split(':', 1)
            parsed = []
            for c in cols.split(';'):
                parts = c.split(' ')
                parsed.append({'type': parts[0], 'name': parts[1],
                               'keys': next((p for p in parts[2:] if p != '?'), ''),
                               'nullable': '?' in parts[2:]})
            tables[name] = parsed
        elif section == 'relaciones':
            src, dst, col = line.split('>')
            fks.append((src, dst.replace('auth.users', 'auth_users'), col))
    return tables, fks


def mermaid(tables, fks):
    out = ['erDiagram']
    for src, dst, col in fks:
        cols = {c['name']: c for c in tables.get(src, [])}
        left = '|o' if cols.get(col, {}).get('nullable') else '||'
        right = '||' if (src, dst) == ('profiles', 'auth_users') else 'o{'
        out.append(f'    {dst.upper()} {left}--{right} {src.upper()} : {col}')
    out.append('    AUTH_USERS {\n        uuid id PK\n    }')
    for name, cols in tables.items():
        out.append(f'    {name.upper()} {{')
        for c in cols:
            keys = ' ' + c['keys'].replace(',', ', ') if c['keys'] else ''
            note = ' "opcional"' if c['nullable'] else ''
            out.append(f'        {c["type"]} {c["name"]}{keys}{note}')
        out.append('    }')
    return '\n'.join(out)


def drawio(tables, fks):
    W, ROW, HEAD, GAP_X, GAP_Y, TITLE = 300, 22, 30, 90, 40, 50
    cells, ids, n = [], {}, [2]

    def nid():
        n[0] += 1
        return f'c{n[0]}'

    for gx, (title, names) in enumerate(GROUPS):
        x = 40 + gx * (W + GAP_X)
        cells.append(f'<mxCell id="{nid()}" value="{escape(title)}" style="text;fontSize=20;fontStyle=1;'
                     f'align=left;verticalAlign=middle;" vertex="1" parent="1">'
                     f'<mxGeometry x="{x}" y="20" width="{W}" height="30" as="geometry"/></mxCell>')
        y = 20 + TITLE + 10
        for name in names:
            cols = tables[name]
            tid = nid()
            ids[name] = tid
            h = HEAD + ROW * len(cols)
            fill = '#d5f5e3' if name in NEW_TABLES else '#dae8fc'
            stroke = '#27ae60' if name in NEW_TABLES else '#6c8ebf'
            cells.append(f'<mxCell id="{tid}" value="{name.upper()}" style="swimlane;fontStyle=1;childLayout=stackLayout;'
                         f'horizontal=1;startSize={HEAD};horizontalStack=0;resizeParent=1;collapsible=1;marginBottom=0;'
                         f'html=1;fillColor={fill};strokeColor={stroke};fontSize=13;" vertex="1" parent="1">'
                         f'<mxGeometry x="{x}" y="{y}" width="{W}" height="{h}" as="geometry"/></mxCell>')
            for i, c in enumerate(cols):
                new = name in NEW_TABLES or c['name'] in NEW_COLUMNS.get(name, set())
                keys = f' <b>{c["keys"]}</b>' if c['keys'] else ''
                opt = ' <i>(opcional)</i>' if c['nullable'] else ''
                label = escape(f'{c["name"]}: {c["type"]}{keys}{opt}', {'"': '&quot;'})
                bg = 'fillColor=#d5f5e3;' if new else 'fillColor=none;'
                cells.append(f'<mxCell id="{nid()}" value="{label}" style="text;html=1;align=left;verticalAlign=middle;'
                             f'spacingLeft=6;fontSize=12;{bg}strokeColor=none;" vertex="1" parent="{tid}">'
                             f'<mxGeometry y="{HEAD + i * ROW}" width="{W}" height="{ROW}" as="geometry"/></mxCell>')
            y += h + GAP_Y

    for src, dst, col in fks:
        if src not in ids or dst not in ids:
            continue
        cells.append(f'<mxCell id="{nid()}" value="{escape(col)}" style="edgeStyle=entityRelationEdgeStyle;'
                     f'endArrow=ERmandOne;startArrow=ERmany;html=1;fontSize=10;strokeColor=#7f8c8d;" '
                     f'edge="1" parent="1" source="{ids[src]}" target="{ids[dst]}">'
                     f'<mxGeometry relative="1" as="geometry"/></mxCell>')

    return ('<mxfile host="app.diagrams.net"><diagram name="ClariaDB v2" id="claria-db-v2">'
            '<mxGraphModel grid="1" gridSize="10" page="0"><root><mxCell id="0"/><mxCell id="1" parent="0"/>'
            + ''.join(cells) + '</root></mxGraphModel></diagram></mxfile>\n')


tables, fks = load()
missing = [t for t in tables if not any(t in g for _, g in GROUPS)]
if missing:
    raise SystemExit(f'Tablas sin grupo en el diagrama: {missing}')

(ROOT / 'docs').mkdir(exist_ok=True)
(ROOT / 'docs' / 'diagrama-er.md').write_text(
    '# Diagrama entidad-relación de ClarIA\n\n'
    'Generado desde la base de datos real con `scripts/esquema_a_diagramas.py`. '
    'GitHub dibuja este diagrama automáticamente. La versión editable está en '
    '[ClariaDB-v2.drawio](ClariaDB-v2.drawio).\n\n```mermaid\n' + mermaid(tables, fks) + '\n```\n',
    encoding='utf-8')
(ROOT / 'docs' / 'ClariaDB-v2.drawio').write_text(drawio(tables, fks), encoding='utf-8')
print(f'{len(tables)} tablas y {len(fks)} relaciones -> docs/diagrama-er.md y docs/ClariaDB-v2.drawio')
