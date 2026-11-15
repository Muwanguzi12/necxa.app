const fs = require('fs');
const path = 'c:/Users/KNEST/necxa app/necxa.app.worktrees/frontend-camera-zoom-improvement/supabase/functions/listing-create/index.ts';
let content = fs.readFileSync(path, 'utf8');

// Replace the insert block
const findInsert = \.insert({
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
          photos: photoPaths, // Store miniatures directly in the JSON column\;

const replaceInsert = \      const supabaseUrl = Deno.env.get("SUPABASE_URL") || "https://lzdtrmjcwzalckszdzpt.supabase.co"
      const fullPhotoPaths = photoPaths.map(p =>
        p.startsWith("http") ? p : \\\\\\/storage/v1/object/public/listing-photos/\\\\\\
      )
      const fullBathroomPaths = bathroomPaths.map(p =>
        p.startsWith("http") ? p : \\\\\\/storage/v1/object/public/listing-photos/\\\\\\
      )
      const fullVideoPaths = videoPaths.map(p =>
        p.startsWith("http") ? p : \\\\\\/storage/v1/object/public/listing-photos/\\\\\\
      )

.insert({
          id: deterministicId,
          user_id: userId,
          lister_id: userId, // Standardized
          title,
          description,
          price: priceUgx,
          price_ugx: priceUgx, // Standardized
          category: propertyType.toUpperCase(),
          is_property_listing: true, // Mark as real-estate so it can be filtered from shop feed
          image_url: fullPhotoPaths.length > 0 ? fullPhotoPaths[0] : null,
          media_url: fullVideoPaths.length > 0 ? fullVideoPaths[0] : (fullPhotoPaths.length > 0 ? fullPhotoPaths[0] : null), 
          media_type: fullVideoPaths.length > 0 ? "video" : "image",
          thumbnail_url: fullPhotoPaths.length > 0 ? fullPhotoPaths[0] : null, // Essential for fast feed loading
          film_hub_content: fullVideoPaths.length > 0 ? fullVideoPaths[0] : null,
          photos: [...fullPhotoPaths, ...fullBathroomPaths], // Store all photos with full CDN paths\;

content = content.replace(findInsert, replaceInsert);

// Replace the property table sync block variables to use the full ones
const findSync = \        const fullPhotoUrls = [...photoPaths, ...bathroomPaths].map(p => \\\\\\/storage/v1/object/public/listing-photos/\\\\\\)\;
const replaceSync = \        const fullPhotoUrls = [...fullPhotoPaths, ...fullBathroomPaths]\;
content = content.replace(findSync, replaceSync);

fs.writeFileSync(path, content, 'utf8');
console.log('Replaced successfully');
