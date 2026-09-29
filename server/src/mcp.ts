/**
 * A minimal MCP server over Streamable HTTP (JSON responses, no server-initiated stream):
 * initialize, notifications/initialized, ping, tools/list, tools/call. Stateless — every POST carries the
 * user's Awan bearer, so no session id is needed.
 */

export type JsonSchema = {
  type?: 'object' | 'string' | 'integer' | 'number' | 'boolean' | 'array';
  description?: string;
  properties?: Record<string, JsonSchema>;
  required?: string[];
  items?: JsonSchema;
  enum?: (string | number)[];
  minimum?: number;
  maximum?: number;
  minItems?: number;
  maxItems?: number;
  default?: unknown;
  additionalProperties?: boolean | JsonSchema;
  format?: string;
};

export type McpTool<Ctx> = {
  name: string;
  title?: string;
  description: string;
  inputSchema: JsonSchema;
  annotations?: { readOnlyHint?: boolean; destructiveHint?: boolean; idempotentHint?: boolean; openWorldHint?: boolean };
  run: (args: Record<string, any>, ctx: Ctx) => Promise<unknown>;
};

export type McpServerSpec<Ctx> = {
  name: string;
  title: string;
  version: string;
  instructions: string;
  tools: McpTool<Ctx>[];
};

export const MCP_PROTOCOL_VERSIONS = ['2025-11-25', '2025-06-18', '2025-03-26', '2024-11-05'];

type JsonRpcRequest = { jsonrpc?: string; id?: string | number | null; method?: string; params?: any };
type JsonRpcResponse = { jsonrpc: '2.0'; id: string | number | null; result?: unknown; error?: { code: number; message: string; data?: unknown } };

/** Checks args against the schema subset the tools use. Returns the first problem, or null. */
export function validateArgs(schema: JsonSchema, value: unknown, path = 'arguments'): string | null {
  if (value === undefined) return null;
  switch (schema.type) {
    case 'object': {
      if (typeof value !== 'object' || value === null || Array.isArray(value)) return `${path} must be an object`;
      const obj = value as Record<string, unknown>;
      for (const r of schema.required ?? []) if (obj[r] === undefined || obj[r] === null) return `${path}.${r} is required`;
      for (const [k, v] of Object.entries(obj)) {
        const sub = schema.properties?.[k];
        if (!sub) {
          if (schema.additionalProperties === false) return `${path}.${k} is not a known argument (expected one of: ${Object.keys(schema.properties ?? {}).join(', ')})`;
          continue;
        }
        const e = validateArgs(sub, v, `${path}.${k}`);
        if (e) return e;
      }
      return null;
    }
    case 'array': {
      if (!Array.isArray(value)) return `${path} must be an array`;
      if (schema.minItems !== undefined && value.length < schema.minItems) return `${path} needs at least ${schema.minItems} item(s)`;
      if (schema.maxItems !== undefined && value.length > schema.maxItems) return `${path} allows at most ${schema.maxItems} item(s)`;
      if (schema.items) {
        for (let i = 0; i < value.length; i++) {
          const e = validateArgs(schema.items, value[i], `${path}[${i}]`);
          if (e) return e;
        }
      }
      return null;
    }
    case 'string':
      if (typeof value !== 'string') return `${path} must be a string`;
      if (schema.enum && !schema.enum.includes(value)) return `${path} must be one of: ${schema.enum.join(', ')}`;
      return null;
    case 'integer':
    case 'number':
      if (typeof value !== 'number' || !Number.isFinite(value) || (schema.type === 'integer' && !Number.isInteger(value))) return `${path} must be ${schema.type === 'integer' ? 'an integer' : 'a number'}`;
      if (schema.minimum !== undefined && value < schema.minimum) return `${path} must be ≥ ${schema.minimum}`;
      if (schema.maximum !== undefined && value > schema.maximum) return `${path} must be ≤ ${schema.maximum}`;
      return null;
    case 'boolean':
      return typeof value === 'boolean' ? null : `${path} must be true or false`;
    default:
      return null;
  }
}

/** Fill schema defaults for top-level properties the caller left out. */
function withDefaults(schema: JsonSchema, args: Record<string, any>): Record<string, any> {
  const out = { ...args };
  for (const [k, sub] of Object.entries(schema.properties ?? {})) {
    if (out[k] === undefined && sub.default !== undefined) out[k] = sub.default;
  }
  return out;
}

export type McpHooks = {
  /** Called before each tools/call; return a message to refuse the call (rate limit). */
  beforeCall?: (tool: string) => string | null;
  /** Map a thrown error to the text the agent sees. */
  describeError?: (err: unknown) => string;
};

/** Handles one JSON-RPC message; returns null for notifications (HTTP 202, no body). */
export async function handleMcpMessage<Ctx>(spec: McpServerSpec<Ctx>, msg: JsonRpcRequest, ctx: Ctx, hooks: McpHooks = {}): Promise<JsonRpcResponse | null> {
  const id = msg?.id ?? null;
  const isNotification = msg?.id === undefined;
  if (!msg || typeof msg !== 'object' || typeof msg.method !== 'string') {
    return { jsonrpc: '2.0', id, error: { code: -32600, message: 'Invalid Request' } };
  }
  const ok = (result: unknown): JsonRpcResponse => ({ jsonrpc: '2.0', id, result });
  switch (msg.method) {
    case 'initialize': {
      const asked = msg.params?.protocolVersion;
      return ok({
        protocolVersion: MCP_PROTOCOL_VERSIONS.includes(asked) ? asked : MCP_PROTOCOL_VERSIONS[1],
        capabilities: { tools: { listChanged: false } },
        serverInfo: { name: spec.name, title: spec.title, version: spec.version },
        instructions: spec.instructions,
      });
    }
    case 'ping':
      return isNotification ? null : ok({});
    case 'tools/list':
      return ok({
        tools: spec.tools.map((t) => ({ name: t.name, title: t.title, description: t.description, inputSchema: t.inputSchema, ...(t.annotations ? { annotations: t.annotations } : {}) })),
      });
    case 'tools/call': {
      const name = msg.params?.name;
      const tool = spec.tools.find((t) => t.name === name);
      if (!tool) return { jsonrpc: '2.0', id, error: { code: -32602, message: `Unknown tool: ${String(name)}` } };
      const args = (msg.params?.arguments ?? {}) as Record<string, any>;
      const bad = validateArgs(tool.inputSchema, args);
      if (bad) return ok({ content: [{ type: 'text', text: `Invalid arguments: ${bad}` }], isError: true });
      const refused = hooks.beforeCall?.(tool.name);
      if (refused) return ok({ content: [{ type: 'text', text: refused }], isError: true });
      try {
        const result = await tool.run(withDefaults(tool.inputSchema, args), ctx);
        const text = typeof result === 'string' ? result : JSON.stringify(result);
        return ok({ content: [{ type: 'text', text }], isError: false });
      } catch (err) {
        const text = hooks.describeError ? hooks.describeError(err) : err instanceof Error ? err.message : String(err);
        return ok({ content: [{ type: 'text', text }], isError: true });
      }
    }
    default:
      if (msg.method.startsWith('notifications/')) return null;
      if (isNotification) return null;
      return { jsonrpc: '2.0', id, error: { code: -32601, message: `Method not found: ${msg.method}` } };
  }
}
