import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type SubmitCommandBody = {
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

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: { ...corsHeaders, "Content-Type": "application/json; charset=utf-8" },
});

const isUuid = (value: unknown): value is string =>
  typeof value === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(value);

const isObject = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

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

  let body: SubmitCommandBody;
  try {
    body = await req.json() as SubmitCommandBody;
  } catch (_error) {
    return json({ error: "invalid_json" }, 400);
  }

  if (!isUuid(body.clientRequestId) || typeof body.title !== "string" || typeof body.goal !== "string" || typeof body.rawText !== "string" || typeof body.taskType !== "string") {
    return json({ error: "invalid_command", fields: ["clientRequestId", "title", "goal", "rawText", "taskType"] }, 400);
  }
  if (body.rawText.trim().length === 0 || body.rawText.length > 2000 || body.title.trim().length === 0 || body.goal.trim().length === 0) {
    return json({ error: "invalid_command_length" }, 400);
  }
  if (body.context !== undefined && !isObject(body.context)) return json({ error: "invalid_context" }, 400);
  if (body.constraints !== undefined && !isObject(body.constraints)) return json({ error: "invalid_constraints" }, 400);

  const { data, error } = await supabase.rpc("submit_captain_command", {
    p_client_request_id: body.clientRequestId,
    p_title: body.title,
    p_goal: body.goal,
    p_raw_text: body.rawText,
    p_task_type: body.taskType,
    p_context: body.context ?? {},
    p_constraints: body.constraints ?? {},
    p_memory_policy: body.memoryPolicy ?? "propose_only",
    p_locale: body.locale ?? "zh-CN",
    p_client_version: body.clientVersion ?? null,
  });
  if (error) return json({ error: "command_rejected", detail: error.message }, 400);
  return json({ ok: true, userId: user.id, ...data });
});
