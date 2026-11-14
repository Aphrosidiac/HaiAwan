// FF Analytics (FF Ops docs/ANALYTICS.md §5): answers /_e, adds the beacon to HTML pages and forwards page,
// beacon and error lines to FF Ops after the response (waitUntil), so it never slows a page. ff-analytics.js is
// FF Ops' apps/api/assets/analytics/ff-analytics.js. Settings: FF_ANALYTICS_URL + FF_ANALYTICS_KEY (Pages secrets).
import { pagesMiddleware } from './ff-analytics.js';

export const onRequest = pagesMiddleware;
