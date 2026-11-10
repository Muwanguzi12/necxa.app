import { createClient } from "https://esm.sh/@supabase/supabase-js@2"

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
}

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  })

const err = (msg: string, status = 400) => json({ success: false, status: "FAILED", error: msg }, status)

const supabaseUrl = Deno.env.get("SUPABASE_URL")
const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")
if (!supabaseUrl || !serviceRoleKey) {
  throw new Error("Missing Supabase Edge Function environment configuration")
}

const supabase = createClient(supabaseUrl, serviceRoleKey, {
  auth: { autoRefreshToken: false, persistSession: false },
})

// Optional secondary Goobox connection. Never embed a service-role key in source.
const gooboxUrl = Deno.env.get("GOOBOX_SUPABASE_URL")
const gooboxKey = Deno.env.get("GOOBOX_SERVICE_ROLE_KEY")
const goobox = gooboxUrl && gooboxKey
  ? createClient(gooboxUrl, gooboxKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    })
  : null

const YOUCAM_API_KEY = Deno.env.get("YOUCAM_API_KEY") || ""
const YOUCAM_BASE_URL = "https://yce-api-01.makeupar.com/s2s/v2.0"

function apiError(payload: any): string {
  const value =
    payload?.data?.error_message ||
    payload?.data?.error ||
    payload?.error_message ||
    payload?.error ||
    payload?.message
  return typeof value === "string" && value.trim()
    ? value.trim().slice(0, 500)
    : "Perfect Corp could not process this request"
}

function normalizeCategory(value: string | undefined): string {
  const category = (value || "").toLowerCase().trim()
  const allowed = new Set(["full_body", "lower_body", "upper_body", "shoes", "auto", "outer"])
  if (allowed.has(category)) return category
  if (["outerwear", "jacket", "coat", "hoodie", "vest"].includes(category)) return "outer"
  if (["earrings", "jewelry", "hat", "accessory", "accessories"].includes(category)) return "auto"
  return "upper_body"
}

async function readListingCategory(listingId?: string): Promise<string | undefined> {
  if (!listingId) return undefined
  const { data, error } = await supabase
    .from("listings")
    .select("title, category, description")
    .eq("id", listingId)
    .maybeSingle()
  if (error || !data) return undefined

  const value = `${data.category || ""} ${data.title || ""} ${data.description || ""}`.toLowerCase()
  if (/\b(dress|suit|jumpsuit|overalls)\b/.test(value)) return "full_body"
  if (/\b(trouser|pants|pant|shorts|short|skirt)\b/.test(value)) return "lower_body"
  if (/\b(shoe|shoes|sneaker|boot|heel|sandal)\b/.test(value)) return "shoes"
  if (/\b(jacket|coat|hoodie|vest|outerwear)\b/.test(value)) return "outer"
  if (/\b(earring|jewelry|jewellery|hat|cap|beanie|accessory)\b/.test(value)) return "auto"
  return "upper_body"
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders })
  if (req.method !== "POST") return err("Method not allowed", 405)

  try {
    const body = await req.json() as {
      action?: string
      src_image_url?: string
      garment_image_url?: string
      garment_category?: string
      task_id?: string
      listing_id?: string
    }

    const action = body.action || "try-on"

    if (action === "check-status") {
      if (!body.task_id) return err("task_id is required")
      if (!YOUCAM_API_KEY) return err("YouCam API key is not configured in Goobox", 503)

      const response = await fetch(
        `${YOUCAM_BASE_URL}/task/cloth-v4/${encodeURIComponent(body.task_id)}`,
        { headers: { Authorization: `Bearer ${YOUCAM_API_KEY}` } },
      )
      const result = await response.json().catch(() => ({}))
      if (!response.ok) {
        return json({
          success: false,
          status: "FAILED",
          error: apiError(result),
          provider_status: response.status,
        }, response.status >= 400 && response.status < 500 ? response.status : 502)
      }

      const rawStatus = String(
        result?.data?.task_status || result?.data?.status || result?.task_status || result?.status || "",
      ).toLowerCase()
      const results = result?.data?.results
      const resultUrl = results?.url ||
        (Array.isArray(results) ? results[0]?.url : null) ||
        result?.data?.result_url ||
        result?.data?.url

      if (["success", "succeeded", "completed", "complete"].includes(rawStatus)) {
        if (!resultUrl) return err("YouCam completed but did not return a result image", 502)
        return json({ success: true, status: "SUCCESS", result_url: resultUrl, task_id: body.task_id })
      }
      if (["failed", "error", "failure"].includes(rawStatus)) {
        return json({ success: false, status: "FAILED", error: apiError(result), task_id: body.task_id }, 502)
      }
      return json({ success: true, status: "PROCESSING", task_id: body.task_id })
    }

    if (action !== "try-on") return err("Unsupported action")
    const { src_image_url, garment_image_url } = body
    if (!src_image_url || !garment_image_url) {
      return err("src_image_url and garment_image_url are required")
    }

    // Room/desk placement is a client-side interactive preview, not a YouCam AI result.
    if (body.garment_category === "spatial_placement") {
      return json({
        success: true,
        status: "MANUAL_PLACEMENT",
        mode: "manual_placement",
        result_url: null,
        variations: [],
      })
    }

    if (!YOUCAM_API_KEY) return err("YouCam API key is not configured in Goobox", 503)

    const inferredCategory = body.garment_category || await readListingCategory(body.listing_id)
    const garmentCategory = normalizeCategory(inferredCategory)

    const response = await fetch(`${YOUCAM_BASE_URL}/task/cloth-v4`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${YOUCAM_API_KEY}`,
      },
      body: JSON.stringify({
        src_file_url: src_image_url,
        ref_file_url: garment_image_url,
        garment_category: garmentCategory,
      }),
    })

    const result = await response.json().catch(() => ({}))
    if (!response.ok) {
      return json({
        success: false,
        status: "FAILED",
        error: apiError(result),
        provider_status: response.status,
      }, response.status >= 400 && response.status < 500 ? response.status : 502)
    }

    const taskId = result?.data?.task_id || result?.task_id
    if (!taskId) {
      return json({
        success: false,
        status: "FAILED",
        error: apiError(result),
      }, 502)
    }

    return json({
      success: true,
      task_id: taskId,
      status: "PROCESSING",
      garment_category: garmentCategory,
    })
  } catch (error) {
    const message = error instanceof Error ? error.message : "Unexpected Experience Engine error"
    console.error("[YouCam Experience]", message)
    return err("Experience request failed. Please try again.", 500)
  }
})
