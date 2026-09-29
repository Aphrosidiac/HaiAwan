/** Drawing / guided-walkthrough tags the app parses itself from `text`; they are only stripped from speech here:
 *  [HIGHLIGHT:x,y,w,h:label] [SHAPE:kind:x,y;x,y…:label] [TARGET:x,y,r:label] [HOVER:x,y,r:label] [IMAGES:query]. */
export const VISUAL_TAG_RE = /\[(?:HIGHLIGHT|SHAPE|TARGET|HOVER|IMAGES):[^\]]*\]/gi;

/**
 * Text Awan types into the user's focused field. A block, because the text can hold brackets, colons and
 * newlines: `[TYPE]text[/TYPE]`, or `[TYPE:x,y:label]text[/TYPE]` to focus the field at x,y first.
 * Never spoken. An unterminated block runs to the end of the reply.
 */
export const TYPE_BLOCK_RE = /\[TYPE(?::[^\]]*)?\]([\s\S]*?)(?:\[\/TYPE\]|$)/gi;

export type Point = { x: number; y: number; label: string | null; screen: number | null };

/**
 * Parses the companion's trailing tags. Supports the reference's protocol
 *   [POINT:x,y:label] / [POINT:x,y:label:screenN] / [POINT:none]
 * plus our extensions: several POINT tags in one reply (step-by-step), and
 *   [AGENT:<task>] — hand the request to an agent,
 *   [IMAGES:<query>] — show an image strip for the answer,
 *   [TYPE]…[/TYPE] — type text into the focused field.
 * Returns the spoken text with every tag removed.
 */
export function parseAssistantTags(text: string): {
  text: string;
  spokenText: string;
  points: Point[];
  agentTask: string | null;
  imagesQuery: string | null;
  typeText: string | null;
} {
  const points: Point[] = [];
  let agentTask: string | null = null;
  const typeMatch = new RegExp(TYPE_BLOCK_RE.source, 'i').exec(text);
  const typeText = typeMatch ? typeMatch[1].replace(/^\n/, '').replace(/\n$/, '') || null : null;
  const withoutType = text.replace(TYPE_BLOCK_RE, ' ');
  const pointRe = /\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:]*?))?(?::screen(\d+))?)\]/gi;
  let m: RegExpExecArray | null;
  while ((m = pointRe.exec(withoutType))) {
    if (m[1] === undefined) continue;
    points.push({ x: Number(m[1]), y: Number(m[2]), label: m[3]?.trim() || null, screen: m[4] ? Number(m[4]) : null });
  }
  const a = /\[AGENT:([^\]]+)\]/i.exec(withoutType);
  if (a) agentTask = a[1].trim();
  const img = /\[IMAGES:([^\]]+)\]/i.exec(withoutType);
  const imagesQuery = img ? img[1].trim() || null : null;
  const spokenText = withoutType
    .replace(pointRe, '')
    .replace(/\[AGENT:[^\]]*\]/gi, '')
    .replace(VISUAL_TAG_RE, '')
    .replace(/[ \t]+\n/g, '\n')
    .replace(/\s{2,}/g, ' ')
    .trim();
  return { text, spokenText, points: points.slice(0, 3), agentTask, imagesQuery, typeText };
}
