// 404 — also the referral fallback for static hosts: awan.ffdev.studio/@handle is not a file,
// so the host serves this page; forward to the home page with ?ref=handle (it restores /@handle).
const m = location.pathname.match(/^\/@([a-z0-9_.-]{1,32})\/?$/i);
if (m) {
  location.replace(`/?ref=${encodeURIComponent(m[1].toLowerCase())}&from=404`);
} else {
  import('./main');
  const p = document.getElementById('nf-path');
  if (p) p.textContent = location.pathname;
}
