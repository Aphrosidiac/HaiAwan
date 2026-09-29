import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { randomBytes } from 'node:crypto';
import { buildApp, generateSuggestions } from './app.ts';
import { openDb, now } from './db.ts';

const dbPath = process.env.DATABASE_PATH || new URL('../data/awan.db', import.meta.url).pathname;
const db = openDb(dbPath);

/**
 * Connector tokens are encrypted with CONNECTOR_KEY. Production must set it (and keep it: losing it means
 * every user reconnects Google). In dev, a throwaway key is generated next to the database (git-ignored)
 * so connectors work out of the box without a real key ever being committed.
 */
function devConnectorKey(): string | undefined {
  if (process.env.CONNECTOR_KEY || process.env.NODE_ENV === 'production') return undefined;
  const file = join(dirname(dbPath), 'connector-dev.key');
  if (!existsSync(file)) {
    mkdirSync(dirname(file), { recursive: true });
    writeFileSync(file, randomBytes(32).toString('base64') + '\n', { mode: 0o600 });
  }
  return readFileSync(file, 'utf8').trim();
}

const app = await buildApp({ db, connectorKey: devConnectorKey() });

// Morning suggestions: once an hour, users whose last suggestion batch is older than 24h get a fresh one.
async function morningSweep() {
  const due = db
    .prepare(
      `SELECT u.id FROM users u WHERE u.deleted_at IS NULL
         AND EXISTS (SELECT 1 FROM awans a WHERE a.user_id = u.id AND a.archived_at IS NULL)
         AND COALESCE((SELECT MAX(created_at) FROM suggestions s WHERE s.user_id = u.id), '') < ?`,
    )
    .all(now(new Date(Date.now() - 24 * 3600_000))) as { id: string }[];
  for (const { id } of due) {
    try {
      const n = await generateSuggestions(db, id, 'morning');
      app.log.info({ user: id, n }, 'morning suggestions');
    } catch (err) {
      app.log.warn({ err, user: id }, 'morning suggestions failed');
    }
  }
}
if (process.env.DISABLE_JOBS !== '1') setInterval(morningSweep, 3600_000).unref();

const port = Number(process.env.PORT || 8787);
await app.listen({ port, host: process.env.HOST || '127.0.0.1' });
