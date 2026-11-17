/** Bloque de texto para mostrar el contenido de lecciones y artículos. */
export type TextBlock =
  | { kind: 'paragraph'; text: string }
  | { kind: 'list'; items: { label: string | null; text: string }[] };

/** Etiquetas cortas al inicio de una viñeta ("Rol: ...") se muestran en negritas. */
const LABEL = /^([^:.]{2,60}):\s+(.+)$/s;

/**
 * Convierte el texto guardado en la base de datos (párrafos separados por una
 * línea en blanco y viñetas que empiezan con "- ") en bloques para la plantilla.
 */
export function toTextBlocks(text: string): TextBlock[] {
  const blocks: TextBlock[] = [];

  for (const chunk of text.split(/\n{2,}/)) {
    const line = chunk.trim();
    if (!line) continue;

    if (line.startsWith('- ')) {
      const item = line.slice(2).trim();
      const match = LABEL.exec(item);
      const entry = match ? { label: match[1], text: match[2] } : { label: null, text: item };
      const last = blocks.at(-1);
      if (last?.kind === 'list') last.items.push(entry);
      else blocks.push({ kind: 'list', items: [entry] });
    } else {
      blocks.push({ kind: 'paragraph', text: line });
    }
  }
  return blocks;
}
