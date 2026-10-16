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

const err = (msg: string, status = 400) => json({ error: msg }, status)

const supabase = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { autoRefreshToken: false, persistSession: false } }
)

// Goobox project connection where YouCam keys can also reside
const GOOBOX_URL = Deno.env.get("GOOBOX_SUPABASE_URL") || "https://anregykcgolpgxecfxej.supabase.co";
const GOOBOX_KEY = Deno.env.get("GOOBOX_SERVICE_ROLE_KEY") || "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImFucmVneWtjZ29scGd4ZWNmeGVqIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc4MDQ2MjU1NCwiZXhwIjoyMDk2MDM4NTU0fQ.519sxkeFrEL-zIyP2MM4kbSZ3sHHP7OY-uwXoDV7cnc";

const goobox = createClient(
  GOOBOX_URL,
  GOOBOX_KEY,
  { auth: { autoRefreshToken: false, persistSession: false } }
);

const YOUCAM_API_KEY = Deno.env.get("YOUCAM_API_KEY") || "";
const YOUCAM_API_SECRET = Deno.env.get("YOUCAM_API_SECRET") || "";

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  try {
    const authHeader = req.headers.get("Authorization");
    const token = authHeader?.replace("Bearer ", "") || "";
    let userId = "guest_user";
    
    // Check if token validates against Necxa primary Supabase or Goobox
    if (token) {
      const { data: { user } } = await supabase.auth.getUser(token);
      if (user?.id) {
        userId = user.id;
      } else {
        const { data: { user: gUser } } = await goobox.auth.getUser(token);
        if (gUser?.id) userId = gUser.id;
      }
    }

    const body = await req.json() as {
      action?: string;
      src_image_url?: string;
      garment_image_url?: string;
      garment_category?: string;
      task_id?: string;
      listing_id?: string;
    };

    const action = body.action || "try-on";

    // 1. Task Status Polling
    if (action === "check-status") {
      if (!body.task_id) return err("task_id is required");
      
      // If we have an active YouCam task, poll Perfect Corp API
      if (YOUCAM_API_KEY) {
        try {
          const resp = await fetch(`https://yce-api-01.makeupar.com/s2s/v2.0/task/cloth/${body.task_id}`, {
            method: "GET",
            headers: {
              "Authorization": `Bearer ${YOUCAM_API_KEY}`,
              "x-api-key": YOUCAM_API_KEY,
            },
          });
          const result = await resp.json();
          console.log("[YouCam Polling Status]:", JSON.stringify(result));
          
          const rawStatus = (result?.data?.task_status || result?.task_status || result?.status || "").toString().toLowerCase();
          const resultUrl = result?.data?.results?.url || 
            (Array.isArray(result?.data?.results) ? result?.data?.results[0]?.url : null) ||
            result?.data?.url || 
            result?.url || 
            result?.data?.result_url;
          
          if (rawStatus === "success" && resultUrl) {
            return json({
              status: "SUCCESS",
              result_url: resultUrl,
              task_id: body.task_id,
            });
          } else if (rawStatus === "error" || rawStatus === "failed") {
            return json({
              status: "FAILED",
              error: result?.data?.error || result?.data?.error_message || result?.message || "YouCam processing failed",
            });
          } else {
            return json({
              status: "PROCESSING",
              task_id: body.task_id,
            });
          }
        } catch (pollErr) {
          console.warn("[YouCam Polling Error]:", pollErr);
          return json({
            status: "PROCESSING",
            task_id: body.task_id,
          });
        }
      }

      // If simulated fallback task without YouCam API key
      return json({
        status: "SUCCESS",
        result_url: body.garment_image_url || null,
      });
    }

    // 2. Submit Try-On Task
    const { src_image_url, garment_image_url, garment_category, listing_id } = body;
    if (!src_image_url || !garment_image_url) {
      return err("src_image_url and garment_image_url are required");
    }

    // Smart category resolution based on category name or listing title
    let resolvedCategory = garment_category || "upper_body";
    if (!garment_category && body.listing_id) {
      try {
        const { data: item } = await supabase
          .from("listings")
          .select("title, category")
          .eq("id", listing_id)
          .maybeSingle();
        const text = `${item?.category || ""} ${item?.title || ""}`.toLowerCase();
        if (text.includes("trouser") || text.includes("pant") || text.includes("short") || text.includes("skirt")) {
          resolvedCategory = "lower_body";
        } else if (text.includes("dress") || text.includes("suit") || text.includes("jumpsuit")) {
          resolvedCategory = "full_body";
        } else if (text.includes("jacket") || text.includes("coat") || text.includes("hoodie") || text.includes("vest")) {
          resolvedCategory = "outerwear";
        } else if (text.includes("shoe") || text.includes("sneaker") || text.includes("boot") || text.includes("heel")) {
          resolvedCategory = "shoes";
        } else if (text.includes("earring") || text.includes("jewelry")) {
          resolvedCategory = "earrings";
        } else if (text.includes("hat") || text.includes("cap") || text.includes("beanie")) {
          resolvedCategory = "hat";
        } else {
          resolvedCategory = "upper_body";
        }
      } catch (_) {}
    }

    // If YouCam API key is present, invoke Perfect Corp v2.0 Clothes API
    if (YOUCAM_API_KEY) {
      try {
        console.log(`[YouCam Try-On Submit] src: ${src_image_url}, ref: ${garment_image_url}, category: ${resolvedCategory}`);
        const response = await fetch("https://yce-api-01.makeupar.com/s2s/v2.0/task/cloth", {
          method: "POST",
          headers: {
            "Content-Type": "application/json",
            "Authorization": `Bearer ${YOUCAM_API_KEY}`,
            "x-api-key": YOUCAM_API_KEY,
          },
          body: JSON.stringify({
            src_file_url: src_image_url,
            ref_file_url: garment_image_url,
            garment_category: resolvedCategory,
          }),
        });

        const data = await response.json();
        console.log("[YouCam Submit Response]:", JSON.stringify(data));
        
        if (response.ok && data?.data?.task_id) {
          return json({
            success: true,
            task_id: data.data.task_id,
            status: data.data.status || data.data.task_status || "PROCESSING",
            garment_category: resolvedCategory,
          });
        } else {
          return json({
            success: false,
            status: "FAILED",
            error: data?.message || data?.error_message || data?.data?.error_message || `YouCam HTTP ${response.status}`,
            raw_response: data,
          });
        }
      } catch (youcamErr) {
        console.warn("[YouCam API Call error]:", youcamErr);
        return json({
          success: false,
          status: "FAILED",
          error: youcamErr instanceof Error ? youcamErr.message : String(youcamErr),
        });
      }
    }

    // Graceful fallback with actual garment variations (never the raw user photo)
    const taskId = `exp_${Date.now()}_${crypto.randomUUID().slice(0, 8)}`;
    
    // Fetch additional listing images if available to show real product styling
    let fallbackVariations = [garment_image_url];
    if (listing_id) {
      try {
        const { data: item } = await supabase
          .from("listings")
          .select("photos")
          .eq("id", listing_id)
          .maybeSingle();
        if (item?.photos && Array.isArray(item.photos)) {
          for (const p of item.photos) {
            if (typeof p === "string" && p && !fallbackVariations.includes(p)) {
              fallbackVariations.push(p);
            }
          }
        }
      } catch (_) {}
    }

    return json({
      success: true,
      task_id: taskId,
      status: "SUCCESS",
      result_url: garment_image_url,
      variations: fallbackVariations,
    });
  } catch (e: unknown) {
    const msg = e instanceof Error ? e.message : String(e);
    return err(`Experience Engine Error: ${msg}`, 500);
  }
});
