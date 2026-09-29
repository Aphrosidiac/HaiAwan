// /download — when a release has been published (app/scripts/release.sh writes /appcast.xml and
// /download/Awan-<version>.dmg), show the real "Download Awan for Mac" button for the newest DMG.
// Otherwise it stays the private-beta waitlist. PLACEHOLDER: the waitlist form posts nowhere.
// Submitting only validates in the browser and shows a note; nothing is sent, stored on a server, or emailed.
import { $, currentReferral } from './main';

interface Release { version: string; url: string; length: number; minimumSystemVersion: string }

/** Newest item of a Sparkle appcast (items are compared by version, not by position). */
export function newestRelease(xml: string): Release | null {
  const doc = new DOMParser().parseFromString(xml, 'application/xml');
  if (doc.querySelector('parsererror')) return null;
  const SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle';
  const cmp = (a: string, b: string) => a.localeCompare(b, undefined, { numeric: true });
  const items = Array.from(doc.getElementsByTagName('item')).flatMap((item) => {
    const enc = item.getElementsByTagName('enclosure')[0];
    const url = enc?.getAttribute('url');
    const version = item.getElementsByTagNameNS(SPARKLE, 'shortVersionString')[0]?.textContent?.trim()
      ?? enc?.getAttributeNS(SPARKLE, 'shortVersionString') ?? '';
    if (!enc || !url || !version || !enc.getAttributeNS(SPARKLE, 'edSignature')) return [];
    return [{ version, url, length: Number(enc.getAttribute('length') ?? 0),
      minimumSystemVersion: item.getElementsByTagNameNS(SPARKLE, 'minimumSystemVersion')[0]?.textContent?.trim() ?? '14.0' }];
  });
  items.sort((a, b) => cmp(b.version, a.version));
  return items[0] ?? null;
}

async function showRelease() {
  try {
    const res = await fetch('/appcast.xml', { cache: 'no-cache' });
    if (!res.ok) return;
    const r = newestRelease(await res.text());
    if (!r) return;
    // Serve the DMG from this site when the appcast was written for another host (staging, local tests).
    const u = new URL(r.url, location.href);
    const href = u.pathname.startsWith('/download/') ? u.pathname : u.href;
    const link = $<HTMLAnchorElement>('#release-link');
    const box = $('#release');
    if (!link || !box) return;
    link.href = href;
    link.setAttribute('download', `Awan-${r.version}.dmg`);
    link.querySelector('span:last-child')!.textContent = 'download awan for mac';
    $('#release-title')!.textContent = `awan ${r.version} for mac`;
    const mb = r.length ? `${Math.round(r.length / 1e6)} mb · ` : '';
    $('#release-meta')!.textContent = `${mb}dmg · macos ${r.minimumSystemVersion} or later · updates are signed and install when you quit`;
    box.hidden = false;
    document.body.classList.add('has-release');
    document.querySelector('.ptitle')!.textContent = 'get awan for mac';
    document.querySelector('.page-head .psub')!.textContent = "drag it to applications, open it, and hold control + option to say hi.";
    document.querySelector('.win .t')!.textContent = 'download';
  } catch {
    /* no appcast yet: keep the waitlist */
  }
}
void showRelease();

const form = $<HTMLFormElement>('#waitlist');
const done = $('#waitlist-done');
const plan = new URLSearchParams(location.search).get('plan');
const planNote = $('#plan-note');
if (plan && planNote && ['pro', 'max'].includes(plan)) {
  planNote.textContent = `you picked ${plan}. plans open when the beta does; you'll start on free until then.`;
  planNote.hidden = false;
}
const ref = currentReferral();
const refNote = $('#ref-note');
if (ref && refNote) {
  refNote.textContent = `${ref} invited you: 25% off your first month of pro or max, kept for 60 days.`;
  refNote.hidden = false;
}

form?.addEventListener('submit', (e) => {
  e.preventDefault();
  if (!form.reportValidity()) return;
  const email = (form.elements.namedItem('email') as HTMLInputElement).value.trim();
  form.hidden = true;
  if (done) {
    done.hidden = false;
    done.textContent = `thanks! heads up though: this form is a placeholder, so ${email} was not sent or saved anywhere. until the waitlist is live, email hello@ffdev.studio and we'll add you by hand.`;
  }
});
