import sys

file_path = r'c:\Users\KNEST\necxa app\necxa.app.worktrees\frontend-camera-zoom-improvement\supabase\functions\listing-create\index.ts'
with open(file_path, 'r', encoding='utf-8') as f:
    content = f.read()

find_str = '''      // Create listing
      const { data: listing, error: listErr } = await supabaseAdmin
        .from("listings")
        .insert({
          id: deterministicId,
          user_id: userId,
          lister_id: userId, // Standardized
          title,
          description,
          price: priceUgx,
          price_ugx: priceUgx, // Standardized
          category: propertyType.toUpperCase(),
          image_url: photoPaths.length > 0 ? photoPaths[0] : null,
          media_url: videoPaths.length > 0 ? videoPaths[0] : (photoPaths.length > 0 ? photoPaths[0] : null), 
          media_type: videoPaths.length > 0 ? "video" : "image",
          thumbnail_url: photoPaths.length > 0 ? photoPaths[0] : null, // Essential for fast feed loading
          film_hub_content: videoPaths.length > 0 ? videoPaths[0] : null,
          photos: photoPaths, // Store miniatures directly in the JSON column'''

replace_str = '''      const supabaseUrl = Deno.env.get("SUPABASE_URL") || "https://lzdtrmjcwzalckszdzpt.supabase.co"
      const fullPhotoPaths = photoPaths.map(p =>
        p.startsWith("http") ? p : ${supabaseUrl}/storage/v1/object/public/listing-photos/
      )
      const fullBathroomPaths = bathroomPaths.map(p =>
        p.startsWith("http") ? p : ${supabaseUrl}/storage/v1/object/public/listing-photos/
      )
      const fullVideoPaths = videoPaths.map(p =>
        p.startsWith("http") ? p : ${supabaseUrl}/storage/v1/object/public/listing-photos/
      )

      // Create listing
      const { data: listing, error: listErr } = await supabaseAdmin
        .from("listings")
        .insert({
          id: deterministicId,
          user_id: userId,
          lister_id: userId, // Standardized
          title,
          description,
          price: priceUgx,
          price_ugx: priceUgx, // Standardized
          category: propertyType.toUpperCase(),
          is_property_listing: true,
          image_url: fullPhotoPaths.length > 0 ? fullPhotoPaths[0] : null,
          media_url: fullVideoPaths.length > 0 ? fullVideoPaths[0] : (fullPhotoPaths.length > 0 ? fullPhotoPaths[0] : null), 
          media_type: fullVideoPaths.length > 0 ? "video" : "image",
          thumbnail_url: fullPhotoPaths.length > 0 ? fullPhotoPaths[0] : null, // Essential for fast feed loading
          film_hub_content: fullVideoPaths.length > 0 ? fullVideoPaths[0] : null,
          photos: [...fullPhotoPaths, ...fullBathroomPaths], // Store all photos with full CDN paths'''

if find_str in content:
    content = content.replace(find_str, replace_str)
    
    # Also fix properties sync block
    sync_find = '''        const fullPhotoUrls = [...photoPaths, ...bathroomPaths].map(p => ${supabaseUrl}/storage/v1/object/public/listing-photos/)'''
    sync_replace = '''        const fullPhotoUrls = [...fullPhotoPaths, ...fullBathroomPaths]'''
    
    content = content.replace(sync_find, sync_replace)
    
    with open(file_path, 'w', encoding='utf-8') as f:
        f.write(content)
    print("Replaced successfully")
else:
    print("Could not find string")
