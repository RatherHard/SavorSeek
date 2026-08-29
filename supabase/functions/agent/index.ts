import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type SubmitCommandBody = {
  command: "submit_command";
  clientRequestId: string;
  title: string;
  goal: string;
  rawText: string;
  taskType: string;
  context?: Record<string, unknown>;
  constraints?: Record<string, unknown>;
  memoryPolicy?: string;
  locale?: string;
  clientVersion?: string;
};

type CancelSessionBody = {
  command: "cancel_session";
  sessionId: string;
};

type GetSessionBody = {
  command: "get_session";
  sessionId: string;
};

type ListEventsBody = {
  command: "list_events";
  sessionId: string;
  afterSequence?: number;
  limit?: number;
};

type RequestBody =
  | SubmitCommandBody
  | CancelSessionBody
  | GetSessionBody
  | ListEventsBody;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
  });

const isUuid = (value: unknown): value is string =>
  typeof value === "string" && UUID_RE.test(value);

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

const TASK_TYPES = [
  "discover_places",
  "compare_recommendations",
  "plan_route",
  "replan_trip",
  "general_exploration",
];

class RpcError extends Error {
  status: number;
  code: string;

  constructor(status: number, code: string, message?: string) {
    super(message ?? code);
    this.status = status;
    this.code = code;
  }
}

async function handle(
  supabase: ReturnType<typeof createClient>,
  body: RequestBody,
): Promise<Response> {
  if (body.command === "submit_command") {
    const { clientRequestId, title, goal, rawText, taskType } = body;
    if (!isUuid(clientRequestId)) throw new RpcError(400, "invalid_client_request_id");
    if (typeof title !== "string" || title.trim().length === 0 || title.length > 120)
      throw new RpcError(400, "invalid_title");
    if (typeof goal !== "string" || goal.trim().length === 0 || goal.length > 2000)
      throw new RpcError(400, "invalid_goal");
    if (typeof rawText !== "string" || rawText.trim().length === 0 || rawText.length > 2000)
      throw new RpcError(400, "invalid_raw_text");
    if (!TASK_TYPES.includes(taskType)) throw new RpcError(400, "invalid_task_type");
    if (body.context !== undefined && !isObject(body.context))
      throw new RpcError(400, "invalid_context");
    if (body.constraints !== undefined && !isObject(body.constraints))
      throw new RpcError(400, "invalid_constraints");

    const { data, error } = await supabase.rpc("submit_captain_command", {
      p_client_request_id: clientRequestId,
      p_title: title,
      p_goal: goal,
      p_raw_text: rawText,
      p_task_type: taskType,
      p_context: body.context ?? {},
      p_constraints: body.constraints ?? {},
      p_memory_policy: body.memoryPolicy ?? "propose_only",
      p_locale: body.locale ?? "zh-CN",
      p_client_version: body.clientVersion ?? null,
    });
    if (error) {
      const conflict = error.code === "23505" || /reused with different/.test(error.message);
      throw new RpcError(conflict ? 409 : 400, "command_rejected", error.message);
    }
    return json({ ok: true, ...data });
  }

  if (body.command === "cancel_session") {
    if (!isUuid(body.sessionId)) throw new RpcError(400, "invalid_session_id");
    const { data, error } = await supabase.rpc("cancel_squad_session", {
      p_session_id: body.sessionId,
    });
    if (error) {
      const notFound = /session not found/.test(error.message);
      const terminal = /terminal status/.test(error.message);
      throw new RpcError(
        notFound ? 404 : terminal ? 409 : 400,
        notFound ? "session_not_found" : terminal ? "session_terminal" : "cancel_rejected",
        error.message,
      );
    }
    return json({ ok: true, ...data });
  }

  if (body.command === "get_session") {
    if (!isUuid(body.sessionId)) throw new RpcError(400, "invalid_session_id");
    const { data, error } = await supabase.rpc("get_squad_session_projection", {
      p_session_id: body.sessionId,
    });
    if (error) {
      const notFound = /session not found/.test(error.message);
      throw new RpcError(notFound ? 404 : 400, notFound ? "session_not_found" : "query_rejected", error.message);
    }
    return json({ ok: true, projection: data });
  }

  if (body.command === "list_events") {
    if (!isUuid(body.sessionId)) throw new RpcError(400, "invalid_session_id");
    const afterSequence = body.afterSequence ?? null;
    const limit = body.limit ?? 100;
    if (afterSequence !== null && (!Number.isInteger(afterSequence) || afterSequence < 0))
      throw new RpcError(400, "invalid_after_sequence");
    if (!Number.isInteger(limit) || limit < 1 || limit > 500)
      throw new RpcError(400, "invalid_limit");
    const { data, error } = await supabase.rpc("list_squad_events", {
      p_session_id: body.sessionId,
      p_after_sequence: afterSequence,
      p_limit: limit,
    });
    if (error) {
      const notFound = /session not found/.test(error.message);
      throw new RpcError(notFound ? 404 : 400, notFound ? "session_not_found" : "query_rejected", error.message);
    }
    return json({ ok: true, ...data });
  }

  throw new RpcError(400, "unknown_command");
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return json({ error: "authentication_required" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const supabaseAnonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !supabaseAnonKey) return json({ error: "function_not_configured" }, 500);

  const supabase = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: { user }, error: userError } = await supabase.auth.getUser();
  if (userError || !user) return json({ error: "authentication_required" }, 401);

  let body: RequestBody;
  try {
    body = (await req.json()) as RequestBody;
  } catch (_error) {
    return json({ error: "invalid_json" }, 400);
  }
  if (!isObject(body) || typeof body.command !== "string") {
    return json({ error: "missing_command" }, 400);
  }

  try {
    return await handle(supabase, body);
  } catch (error) {
    if (error instanceof RpcError) return json({ error: error.code, detail: error.message }, error.status);
    return json({ error: "internal_error" }, 500);
  }
});
