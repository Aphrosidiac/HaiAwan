/**
 * Integration catalogue. The reference brokers these through Composio; Awan connects each one as
 * a remote MCP server in the agent runtime, and the runtime's own MCP OAuth handles sign-in.
 * `auth: 'awan-google'` = first-party: Awan's server hosts the MCP server at `/mcp/<id>` and holds the
 * Google grant (Connect → /v1/connectors/google/start). `url: null` otherwise means there is no public
 * hosted server we can vouch for — the app asks the user for their server URL or key.
 */
export type Integration = {
  id: string;
  name: string;
  description: string;
  url: string | null;
  auth: 'oauth' | 'api_key' | 'none' | 'local' | 'awan-google';
  icon: string; // SF Symbol fallback; the app ships brand-neutral glyphs
  category: 'productivity' | 'dev' | 'google' | 'social' | 'commerce' | 'design' | 'local';
};

export const INTEGRATIONS: Integration[] = [
  { id: 'notion', name: 'Notion', description: 'Search pages and databases, read content, then create, update, comment on or organise pages, blocks and rows.', url: 'https://mcp.notion.com/mcp', auth: 'oauth', icon: 'doc.richtext', category: 'productivity' },
  { id: 'linear', name: 'Linear', description: 'Search issues, teams, projects, cycles and labels, then create or update issues, comments and milestones.', url: 'https://mcp.linear.app/mcp', auth: 'oauth', icon: 'line.3.diagonal', category: 'dev' },
  { id: 'github', name: 'GitHub', description: 'Search repositories, inspect issues, PRs, commits, releases and Actions, then create or update repo work with approval.', url: 'https://api.githubcopilot.com/mcp/', auth: 'oauth', icon: 'chevron.left.forwardslash.chevron.right', category: 'dev' },
  { id: 'gmail', name: 'Gmail', description: 'Search and read mail with attachments listed, manage labels, draft new mail and replies, and send a draft once you approve it.', url: null, auth: 'awan-google', icon: 'envelope', category: 'google' },
  { id: 'google-calendar', name: 'Google Calendar', description: 'List calendars and events, find free time, then create, move, update or delete events.', url: null, auth: 'awan-google', icon: 'calendar', category: 'google' },
  { id: 'google-docs', name: 'Google Docs', description: 'Create documents, read them as text, append to them and find-and-replace inside them.', url: null, auth: 'awan-google', icon: 'doc.text', category: 'google' },
  { id: 'google-sheets', name: 'Google Sheets', description: 'Create spreadsheets and tabs, read ranges, append rows and write cells.', url: null, auth: 'awan-google', icon: 'tablecells', category: 'google' },
  { id: 'google-drive', name: 'Google Drive', description: 'Search files, read details, read Docs/Sheets/text files as text, upload, share and move files.', url: null, auth: 'awan-google', icon: 'externaldrive', category: 'google' },
  { id: 'slack', name: 'Slack', description: 'Search Slack, read channels and threads, manage reminders and canvases, and draft or send messages with approval.', url: null, auth: 'oauth', icon: 'number', category: 'productivity' },
  { id: 'linkedin', name: 'LinkedIn', description: 'Draft and publish posts, comment, and review profiles, companies and content metrics.', url: null, auth: 'oauth', icon: 'person.crop.square', category: 'social' },
  { id: 'asana', name: 'Asana', description: 'Search projects and tasks, then create or update tasks, subtasks, comments and project status.', url: 'https://mcp.asana.com/sse', auth: 'oauth', icon: 'circle.grid.2x1', category: 'productivity' },
  { id: 'atlassian', name: 'Jira & Confluence', description: 'Search and update Jira issues and Confluence pages across your Atlassian site.', url: 'https://mcp.atlassian.com/v1/sse', auth: 'oauth', icon: 'square.stack.3d.up', category: 'dev' },
  { id: 'monday', name: 'monday.com', description: 'Read and update boards, items, updates and workspaces.', url: 'https://mcp.monday.com/sse', auth: 'oauth', icon: 'rectangle.split.3x1', category: 'productivity' },
  { id: 'box', name: 'Box', description: 'Search, download, upload, share, classify and organise Box files and folders.', url: 'https://mcp.box.com', auth: 'oauth', icon: 'shippingbox', category: 'productivity' },
  { id: 'canva', name: 'Canva', description: 'Find, create and export Canva designs.', url: 'https://mcp.canva.com/mcp', auth: 'oauth', icon: 'paintpalette', category: 'design' },
  { id: 'figma', name: 'Figma', description: 'Read Figma files and frames, pull design context, and inspect components.', url: 'https://mcp.figma.com/mcp', auth: 'oauth', icon: 'square.on.circle', category: 'design' },
  { id: 'webflow', name: 'Webflow', description: 'Manage Webflow sites, CMS collections and items.', url: 'https://mcp.webflow.com/sse', auth: 'oauth', icon: 'globe', category: 'design' },
  { id: 'stripe', name: 'Stripe', description: 'Look up customers, payments, invoices and subscriptions; create payment links with approval.', url: 'https://mcp.stripe.com', auth: 'oauth', icon: 'creditcard', category: 'commerce' },
  { id: 'paypal', name: 'PayPal', description: 'Look up transactions, invoices and disputes.', url: 'https://mcp.paypal.com/mcp', auth: 'oauth', icon: 'dollarsign.circle', category: 'commerce' },
  { id: 'square', name: 'Square', description: 'Read catalogue, orders, customers and payments.', url: 'https://mcp.squareup.com/sse', auth: 'oauth', icon: 'square', category: 'commerce' },
  { id: 'intercom', name: 'Intercom', description: 'Search conversations and contacts, and review support history.', url: 'https://mcp.intercom.com/mcp', auth: 'oauth', icon: 'bubble.left.and.bubble.right', category: 'productivity' },
  { id: 'sentry', name: 'Sentry', description: 'Inspect issues, events, releases and performance data.', url: 'https://mcp.sentry.dev/mcp', auth: 'oauth', icon: 'ant', category: 'dev' },
  { id: 'vercel', name: 'Vercel', description: 'Inspect projects, deployments and logs.', url: 'https://mcp.vercel.com', auth: 'oauth', icon: 'triangle', category: 'dev' },
  { id: 'supabase', name: 'Supabase', description: 'Query and manage Supabase projects, tables, and edge functions.', url: 'https://mcp.supabase.com/mcp', auth: 'oauth', icon: 'bolt', category: 'dev' },
  { id: 'obsidian', name: 'Obsidian', description: "Use a local Markdown vault through Awan's Obsidian skill. No account needed.", url: null, auth: 'local', icon: 'diamond', category: 'local' },
];
