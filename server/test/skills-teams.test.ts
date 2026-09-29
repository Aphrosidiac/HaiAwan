import { test } from 'node:test';
import assert from 'node:assert/strict';
import { buildApp, companionSkills } from '../src/app.ts';
import { openDb } from '../src/db.ts';
import { consume, planFor, QuotaExceeded } from '../src/plans.ts';
import { ACTIVE_SKILLS_MAX_CHARS, activeSkillsBlock, parseSkillMarkdown, validateSkillDraft } from '../src/skills.ts';
import { OFFICIAL_SKILLS, CATEGORIES } from '../src/skills-seed.ts';
import { normaliseInviteCode } from '../src/teams.ts';

process.env.LOG = '0';

let writerCalls = 0;
async function setup() {
  const db = openDb(':memory:');
  const app = await buildApp({
    db,
    devMode: true,
    publicUrl: 'http://api.test',
    siteUrl: 'http://site.test',
    skillWriter: async (dump) => {
      writerCalls++;
      return validateSkillDraft({
        title: 'Kopi Menu Writer',
        oneLiner: 'Writes café menu descriptions that make people hungry.',
        whatsInside: ['Short sensory lines', 'Prices kept as given'],
        category: 'writing',
        content: `You write menu copy for a small café.\n\n## When to apply\n- ${dump}\n\n## How to help\n- Type the line into the focused field.`,
      });
    },
  });
  return { db, app };
}

async function signIn(app: Awaited<ReturnType<typeof setup>>['app'], email: string) {
  const r = await app.inject({ method: 'POST', url: '/v1/auth/magic', payload: { email } });
  const code = new URL(r.json().devLink).searchParams.get('code')!;
  const v = await app.inject({ method: 'GET', url: `/auth/verify?code=${code}` });
  const token = decodeURIComponent(/token=([^"&]+)/.exec(v.body)![1]);
  return { authorization: `Bearer ${token}` };
}

const userId = async (app: Awaited<ReturnType<typeof setup>>['app'], h: Record<string, string>) =>
  (await app.inject({ method: 'GET', url: '/v1/me', headers: h })).json().user.id as string;

// ───────────────────────────── skills ─────────────────────────────

test('seed: ~30 official skills across all 8 categories, each with the SKILL.md sections', async () => {
  assert.ok(OFFICIAL_SKILLS.length >= 28 && OFFICIAL_SKILLS.length <= 32);
  assert.deepEqual(new Set(OFFICIAL_SKILLS.map((s) => s.category)), new Set(Object.keys(CATEGORIES)));
  assert.equal(new Set(OFFICIAL_SKILLS.map((s) => s.slug)).size, OFFICIAL_SKILLS.length, 'slugs are unique');
  for (const s of OFFICIAL_SKILLS) {
    assert.match(s.content, /## When to apply/, s.slug);
    assert.match(s.content, /## How to help/, s.slug);
    assert.ok(s.oneLiner.length <= 110, s.slug);
  }
  const { app } = await setup();
  const h = await signIn(app, 'lib@b.co');
  const lib = (await app.inject({ method: 'GET', url: '/v1/skills/library', headers: h })).json();
  assert.equal(lib.skills.length, OFFICIAL_SKILLS.length);
  assert.equal(lib.maxActive, 3);
  assert.equal(lib.skills[0].content, undefined, 'the list omits bodies; the detail has them');
  const one = (await app.inject({ method: 'GET', url: `/v1/skills/${lib.skills[0].slug}`, headers: h })).json().skill;
  assert.ok(one.content.length > 100);
});

test('three slots: the 4th activation is a 409 naming the active three; replace swaps in one transaction', async () => {
  const { app } = await setup();
  const h = await signIn(app, 'slots@b.co');
  const slugs = OFFICIAL_SKILLS.slice(0, 5).map((s) => s.slug);
  for (const slug of slugs.slice(0, 3)) {
    assert.equal((await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug } })).statusCode, 200);
  }
  const again = await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug: slugs[0] } });
  assert.equal(again.statusCode, 200, 'activating an active skill is a no-op');
  const full = await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug: slugs[3] } });
  assert.equal(full.statusCode, 409);
  assert.equal(full.json().error, 'slots_full');
  assert.deepEqual(full.json().activeSlugs, slugs.slice(0, 3));
  const swap = await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug: slugs[3], replace: slugs[1] } });
  assert.equal(swap.statusCode, 200);
  assert.deepEqual(new Set(swap.json().activeSlugs), new Set([slugs[0], slugs[2], slugs[3]]));
  const off = await app.inject({ method: 'POST', url: '/v1/skills/deactivate', headers: h, payload: { slug: slugs[0] } });
  assert.equal(off.json().activeSlugs.length, 2);
  const active = (await app.inject({ method: 'GET', url: '/v1/skills/active', headers: h })).json();
  assert.equal(active.skills.length, 2);
  assert.ok(active.skills.every((s: { content: string }) => s.content.length > 0));
  // users_count counts people, not toggles
  await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug: slugs[0] } });
  const lib = (await app.inject({ method: 'GET', url: '/v1/skills/library', headers: h })).json();
  assert.equal(lib.skills.find((s: { slug: string }) => s.slug === slugs[0]).usersCount, 1);
});

test('three slots hold under concurrent activation', async () => {
  const { app } = await setup();
  const h = await signIn(app, 'race@b.co');
  const slugs = OFFICIAL_SKILLS.slice(0, 8).map((s) => s.slug);
  const results = await Promise.all(slugs.map((slug) => app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug } })));
  assert.equal(results.filter((r) => r.statusCode === 200).length, 3);
  assert.equal(results.filter((r) => r.statusCode === 409).length, 5);
  const active = (await app.inject({ method: 'GET', url: '/v1/skills/active', headers: h })).json();
  assert.equal(active.skills.length, 3);
});

test('activations sync (onboarding picks): at most 3, unknown slugs refused', async () => {
  const { app } = await setup();
  const h = await signIn(app, 'sync@b.co');
  const s = OFFICIAL_SKILLS.map((x) => x.slug);
  const ok = await app.inject({ method: 'POST', url: '/v1/skills/activations/sync', headers: h, payload: { activeSlugs: [s[0], s[1]] } });
  assert.deepEqual(ok.json().activeSlugs, [s[0], s[1]]);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/skills/activations/sync', headers: h, payload: { activeSlugs: s.slice(0, 4) } })).statusCode, 400);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/skills/activations/sync', headers: h, payload: { activeSlugs: ['nope'] } })).statusCode, 404);
  const swapped = await app.inject({ method: 'POST', url: '/v1/skills/activations/sync', headers: h, payload: { activeSlugs: [s[2]] } });
  assert.deepEqual(swapped.json().activeSlugs, [s[2]]);
});

test('create, ownership, publish and the All / My skills filters', async () => {
  const { app } = await setup();
  const a = await signIn(app, 'author@b.co');
  const b = await signIn(app, 'other@b.co');
  const before = writerCalls;
  const created = await app.inject({ method: 'POST', url: '/v1/skills/create', headers: a, payload: { brainDump: 'menu descriptions for my kopitiam, short and warm' } });
  assert.equal(created.statusCode, 200);
  assert.equal(writerCalls, before + 1);
  const skill = created.json().skill;
  assert.equal(skill.isMine, true);
  assert.equal(skill.published, false);
  assert.equal(skill.origin, 'created');
  assert.equal((await app.inject({ method: 'POST', url: '/v1/skills/create', headers: a, payload: { brainDump: 'short' } })).statusCode, 400);

  // private: the other user can neither see nor activate nor edit it
  assert.equal((await app.inject({ method: 'GET', url: `/v1/skills/${skill.slug}`, headers: b })).statusCode, 404);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: b, payload: { slug: skill.slug } })).statusCode, 404);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/skills/${skill.slug}`, headers: b, payload: { title: 'Mine now' } })).statusCode, 404);

  const mine = (await app.inject({ method: 'GET', url: '/v1/skills/library?filter=mine', headers: a })).json();
  assert.deepEqual(mine.skills.map((s: { slug: string }) => s.slug), [skill.slug]);
  const all = (await app.inject({ method: 'GET', url: '/v1/skills/library?filter=all', headers: b })).json();
  assert.ok(!all.skills.some((s: { slug: string }) => s.slug === skill.slug));

  // publish → everyone sees it, but only the author may edit it; official skills are nobody's to edit
  assert.equal((await app.inject({ method: 'POST', url: `/v1/skills/${skill.slug}/publish`, headers: a })).statusCode, 200);
  assert.equal((await app.inject({ method: 'GET', url: `/v1/skills/${skill.slug}`, headers: b })).statusCode, 200);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/skills/${skill.slug}`, headers: b, payload: { title: 'Mine now' } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'POST', url: `/v1/skills/${skill.slug}/unpublish`, headers: b })).statusCode, 403);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/skills/${OFFICIAL_SKILLS[0].slug}`, headers: a, payload: { title: 'x' } })).statusCode, 403);
  const patched = await app.inject({ method: 'PATCH', url: `/v1/skills/${skill.slug}`, headers: a, payload: { title: 'Kopi Copy', color: '#123456' } });
  assert.equal(patched.statusCode, 200);
  assert.equal(patched.json().skill.title, 'Kopi Copy');
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/skills/${skill.slug}`, headers: a, payload: { color: 'red' } })).statusCode, 400);

  // search
  const found = (await app.inject({ method: 'GET', url: '/v1/skills/library?q=kopi', headers: b })).json();
  assert.deepEqual(found.skills.map((s: { slug: string }) => s.slug), [skill.slug]);
  const pct = await app.inject({ method: 'GET', url: '/v1/skills/library?q=%25', headers: b });
  assert.equal(pct.json().skills.length, 0, 'a literal % is not a wildcard');
});

test('import: front matter with name + description is required', async () => {
  const { app } = await setup();
  const h = await signIn(app, 'imp@b.co');
  const good = '---\nname: sambal-scale\ndescription: "Scales sambal recipes for a crowd."\ncategory: fun\n---\n\nYou scale recipes.\n\n## When to apply\n- Big batches.\n';
  const r = await app.inject({ method: 'POST', url: '/v1/skills/import', headers: h, payload: { markdown: good } });
  assert.equal(r.statusCode, 200);
  assert.equal(r.json().skill.title, 'Sambal Scale');
  assert.equal(r.json().skill.category, 'fun');
  assert.equal(r.json().skill.origin, 'imported');
  assert.deepEqual(r.json().skill.whatsInside, ['When to apply']);
  for (const [md, err] of [
    ['just text', 'missing_front_matter'],
    ['---\ndescription: x\n---\nbody', 'front_matter_needs_name'],
    ['---\nname: x\n---\nbody', 'front_matter_needs_description'],
    ['---\nname: x\ndescription: y\n---\n', 'empty_skill'],
  ]) {
    const bad = await app.inject({ method: 'POST', url: '/v1/skills/import', headers: h, payload: { markdown: md } });
    assert.equal(bad.statusCode, 400, md);
    assert.equal(bad.json().error, err);
  }
  assert.throws(() => parseSkillMarkdown('no'));
});

test('<active_skills> block: wrapped, ordered, trimmed to 6k in total', async () => {
  const long = 'x'.repeat(10_000);
  const block = activeSkillsBlock([
    { title: 'One', slug: 'one', content: long },
    { title: 'Two', slug: 'two', content: 'short body' },
    { title: 'Three "q"', slug: 'three', content: long },
  ])!;
  assert.ok(block.length <= ACTIVE_SKILLS_MAX_CHARS, `block is ${block.length}`);
  assert.ok(block.startsWith('<active_skills>'));
  assert.ok(block.endsWith('</active_skills>'));
  assert.match(block, /<skill name="One" slug="one">/);
  assert.match(block, /short body/);
  assert.match(block, /…\n<\/skill>/);
  assert.equal(activeSkillsBlock([]), null);

  const { app, db } = await setup();
  const h = await signIn(app, 'block@b.co');
  const id = await userId(app, h);
  await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: h, payload: { slug: OFFICIAL_SKILLS[0].slug } });
  assert.deepEqual(companionSkills(db, id).map((s) => s.slug), [OFFICIAL_SKILLS[0].slug], 'no field → the account set');
  assert.deepEqual(companionSkills(db, id, [OFFICIAL_SKILLS[4].slug, 'ghost']).map((s) => s.slug), [OFFICIAL_SKILLS[4].slug], 'field wins; unknown dropped');
  assert.deepEqual(companionSkills(db, id, []), []);
});

// ───────────────────────────── teams ─────────────────────────────

async function teamWith(app: Awaited<ReturnType<typeof setup>>['app']) {
  const owner = await signIn(app, 'owner@team.co');
  const created = await app.inject({ method: 'POST', url: '/v1/teams', headers: owner, payload: { name: 'Kopi Senja' } });
  assert.equal(created.statusCode, 200);
  const teamId = created.json().team.id as string;
  const invite = async (seat: string, email?: string) =>
    (await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/invites`, headers: owner, payload: { seat, email } })).json().invite.code as string;
  return { owner, teamId, invite };
}

test('teams: create gives the owner a Max seat in dev; a second team is refused', async () => {
  const { app } = await setup();
  const { owner } = await teamWith(app);
  const me = (await app.inject({ method: 'GET', url: '/v1/me', headers: owner })).json();
  assert.equal(me.plan.tier, 'max');
  assert.equal(me.plan.plan_source, 'team');
  assert.equal(me.plan.team.name, 'Kopi Senja');
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams', headers: owner, payload: { name: 'Again' } })).statusCode, 409);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams', headers: await signIn(app, 'x@y.co'), payload: { name: ' ' } })).statusCode, 400);
});

test('teams: invites are single use, email-bound when given, and expire', async () => {
  const { app, db } = await setup();
  const { invite } = await teamWith(app);
  const code = await invite('pro');
  const m1 = await signIn(app, 'm1@team.co');
  const m2 = await signIn(app, 'm2@team.co');
  const joined = await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m1, payload: { code: code.toLowerCase().replace('awn-', '') } });
  assert.equal(joined.statusCode, 200, 'codes are forgiving about case and prefix');
  assert.equal(joined.json().me.seat, 'pro');
  const reuse = await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m2, payload: { code } });
  assert.equal(reuse.statusCode, 409);
  assert.equal(reuse.json().error, 'code_already_used');

  const bound = await invite('max', 'someone@else.co');
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m2, payload: { code: bound } })).statusCode, 403);

  const old = await invite('pro');
  db.prepare('UPDATE team_invites SET expires_at = ? WHERE code = ?').run('2000-01-01T00:00:00.000Z', old);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m2, payload: { code: old } })).statusCode, 410);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m2, payload: { code: 'AWN-ZZZZ-ZZZZ' } })).statusCode, 404);

  // racing joins on one code: exactly one wins
  const race = await invite('pro');
  const racers = await Promise.all(['r1', 'r2', 'r3'].map(async (n) => app.inject({ method: 'POST', url: '/v1/teams/join', headers: await signIn(app, `${n}@team.co`), payload: { code: race } })));
  assert.equal(racers.filter((r) => r.statusCode === 200).length, 1);
  assert.equal(normaliseInviteCode(' awn abcd efgh '), 'AWN-ABCD-EFGH');
});

test('teams: permission matrix — members can’t manage, admins manage members only, only the owner sets roles', async () => {
  const { app } = await setup();
  const { owner, teamId, invite } = await teamWith(app);
  const member = await signIn(app, 'mem@team.co');
  const admin = await signIn(app, 'adm@team.co');
  const other = await signIn(app, 'mem2@team.co');
  for (const h of [member, admin, other]) await app.inject({ method: 'POST', url: '/v1/teams/join', headers: h, payload: { code: await invite('pro') } });
  const [ownerId, memberId, adminId, otherId] = await Promise.all([owner, member, admin, other].map((h) => userId(app, h)));

  // member: no invites, no seat changes, no removals
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/invites`, headers: member, payload: { seat: 'pro' } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${otherId}`, headers: member, payload: { seat: 'max' } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${otherId}`, headers: member })).statusCode, 403);
  const view = (await app.inject({ method: 'GET', url: '/v1/teams/me', headers: member })).json();
  assert.equal(view.me.canManage, false);
  assert.deepEqual(view.invites, [], 'members never see invite codes');

  // owner promotes admin; admin still can't touch roles
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${adminId}`, headers: owner, payload: { role: 'admin' } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${memberId}`, headers: admin, payload: { role: 'admin' } })).statusCode, 403);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${ownerId}`, headers: owner, payload: { role: 'member' } })).statusCode, 400);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${memberId}`, headers: owner, payload: { role: 'owner' } })).statusCode, 400);

  // admin: invites and seats yes
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/invites`, headers: admin, payload: { seat: 'max' } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${memberId}`, headers: admin, payload: { seat: 'max' } })).statusCode, 200);
  // admin can remove a member but not the owner
  assert.equal((await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${ownerId}`, headers: admin })).statusCode, 400);
  assert.equal((await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${otherId}`, headers: admin })).statusCode, 200);
  // a member may leave on their own; the owner may remove an admin
  assert.equal((await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${memberId}`, headers: member })).statusCode, 200);
  assert.equal((await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${adminId}`, headers: owner })).statusCode, 200);
  const final = (await app.inject({ method: 'GET', url: '/v1/teams/me', headers: owner })).json();
  assert.equal(final.members.length, 1);
  // someone outside the team can't act on it
  assert.equal((await app.inject({ method: 'POST', url: `/v1/teams/${teamId}/invites`, headers: other, payload: { seat: 'pro' } })).statusCode, 403);
});

test('teams: the seat plan sets the caps; leaving falls back to the personal plan', async () => {
  const { app, db } = await setup();
  const { teamId, owner, invite } = await teamWith(app);
  const m = await signIn(app, 'caps@team.co');
  const id = await userId(app, m);
  for (let i = 0; i < 25; i++) consume(db, id, 'talk', `t${i}`);
  assert.throws(() => consume(db, id, 'talk', 't25'), QuotaExceeded, 'free cap before joining');
  await app.inject({ method: 'POST', url: '/v1/teams/join', headers: m, payload: { code: await invite('pro') } });
  assert.equal(planFor(db, id).plan, 'pro');
  consume(db, id, 'talk', 't25'); // pro: talk is unlimited
  const snap = (await app.inject({ method: 'GET', url: '/v1/billing/plan', headers: m })).json();
  assert.equal(snap.usage.agents.cap, 150);
  assert.equal(snap.team.seat, 'pro');
  await app.inject({ method: 'PATCH', url: `/v1/teams/${teamId}/members/${id}`, headers: owner, payload: { seat: 'max' } });
  assert.equal((await app.inject({ method: 'GET', url: '/v1/billing/plan', headers: m })).json().usage.agents.cap, 1000);
  // the team's subscription status applies to every seat
  db.prepare("UPDATE teams SET status = 'canceled' WHERE id = ?").run(teamId);
  assert.equal(planFor(db, id).plan, 'free');
  db.prepare("UPDATE teams SET status = 'active' WHERE id = ?").run(teamId);
  await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${id}`, headers: m });
  assert.equal(planFor(db, id).plan, 'free');
});

test('teams: share-to-team shows a skill under Team for teammates only, and leaving unshares it', async () => {
  const { app } = await setup();
  const { invite, teamId } = await teamWith(app);
  const author = await signIn(app, 'writer@team.co');
  const outsider = await signIn(app, 'out@b.co');
  const teammate = await signIn(app, 'mate@team.co');
  assert.equal(
    (await app.inject({ method: 'POST', url: '/v1/skills/import', headers: outsider, payload: { markdown: '---\nname: a\ndescription: b\n---\nc' } })).statusCode,
    200,
  );
  const s = (await app.inject({ method: 'POST', url: '/v1/skills/create', headers: author, payload: { brainDump: 'our house style for client proposals' } })).json().skill;
  assert.equal((await app.inject({ method: 'POST', url: `/v1/skills/${s.slug}/share-to-team`, headers: author })).statusCode, 409, 'not in a team yet');
  for (const h of [author, teammate]) await app.inject({ method: 'POST', url: '/v1/teams/join', headers: h, payload: { code: await invite('pro') } });
  assert.equal((await app.inject({ method: 'POST', url: `/v1/skills/${s.slug}/share-to-team`, headers: author })).statusCode, 200);
  const team = (await app.inject({ method: 'GET', url: '/v1/skills/library?filter=team', headers: teammate })).json();
  assert.deepEqual(team.skills.map((x: { slug: string }) => x.slug), [s.slug]);
  assert.equal(team.skills[0].teamShared, true);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/skills/activate', headers: teammate, payload: { slug: s.slug } })).statusCode, 200);
  assert.equal((await app.inject({ method: 'GET', url: `/v1/skills/${s.slug}`, headers: outsider })).statusCode, 404);
  assert.equal((await app.inject({ method: 'GET', url: '/v1/skills/library?filter=team', headers: outsider })).json().skills.length, 0);
  const detail = (await app.inject({ method: 'GET', url: '/v1/teams/me', headers: teammate })).json();
  assert.equal(detail.skills[0].slug, s.slug);
  // the author leaves → the skill is no longer shared, and drops out of the teammate's active set
  const authorId = await userId(app, author);
  await app.inject({ method: 'DELETE', url: `/v1/teams/${teamId}/members/${authorId}`, headers: author });
  assert.equal((await app.inject({ method: 'GET', url: '/v1/skills/active', headers: teammate })).json().skills.length, 0);
});

test('team dashboard: one-time link → cookie session; forms need the CSRF token; members see no manage controls', async () => {
  const { app } = await setup();
  const { owner } = await teamWith(app);
  assert.equal((await app.inject({ method: 'POST', url: '/v1/teams/dashboard-link', headers: await signIn(app, 'solo@b.co') })).statusCode, 409);
  const link = (await app.inject({ method: 'POST', url: '/v1/teams/dashboard-link', headers: owner })).json().url as string;
  const path = link.replace('http://api.test', '');
  const first = await app.inject({ method: 'GET', url: path });
  assert.equal(first.statusCode, 302);
  const cookie = String(first.headers['set-cookie']).split(';')[0];
  assert.match(String(first.headers['set-cookie']), /HttpOnly; SameSite=Lax; Path=\/team/);
  assert.equal((await app.inject({ method: 'GET', url: path })).statusCode, 400, 'links work once');
  assert.equal((await app.inject({ method: 'GET', url: '/team' })).statusCode, 401, 'no cookie, no dashboard');
  const page = await app.inject({ method: 'GET', url: '/team', headers: { cookie } });
  assert.equal(page.statusCode, 200);
  assert.match(page.body, /Kopi Senja/);
  assert.match(page.body, /Create invite/);
  const csrf = /name="csrf" value="([^"]+)"/.exec(page.body)![1];
  const forged = await app.inject({ method: 'POST', url: '/team/invite', headers: { cookie }, payload: { seat: 'pro', csrf: 'nope' } });
  assert.equal(forged.statusCode, 403);
  const made = await app.inject({ method: 'POST', url: '/team/invite', headers: { cookie, 'content-type': 'application/x-www-form-urlencoded' }, payload: `seat=max&email=&csrf=${encodeURIComponent(csrf)}` });
  assert.equal(made.statusCode, 302);
  assert.match(decodeURIComponent(String(made.headers.location)), /Invite code AWN-/);
  const after = await app.inject({ method: 'GET', url: '/team', headers: { cookie } });
  assert.match(after.body, /<code>AWN-/);
  assert.doesNotMatch(after.body, /<script/i, 'no scripts: user content is escaped');
});
