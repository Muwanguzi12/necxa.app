const fs = require('fs');
const path = require('path');
const fetch = require('node-fetch');

const SUPABASE_URL = 'https://anregykcgolpgxecfxej.supabase.co';
let envKey = process.env.SUPABASE_SERVICE_KEY;
if (!envKey && fs.existsSync('.env')) {
  const envContent = fs.readFileSync('.env', 'utf-8');
  const match = envContent.match(/SUPABASE_SERVICE_ROLE_KEY=(.+)/);
  if (match) envKey = match[1].trim();
}
const SERVICE_KEY = envKey;
const BUCKET = 'gift-icons';
const IMAGE_DIR = 'D:\\downloads\\gift  icons\\gift icons';

// Full mapping: original filename -> storage name (gift_type key)
const GIFT_MAP = [
  { file: 'file_00000000c24481f483798d796fa9e5ab.png', name: 'money_bag.jpeg', label: 'Money Bag',  ncx: 100 },
  { file: 'file_00000000898c81f4bafd3c88dd3fdfcd.png', name: 'yacht.jpeg',     label: 'Yacht',      ncx: 500 },
  { file: 'file_00000000218481f488f653dcf7520c10.png', name: 'mansion.jpeg',   label: 'Mansion',    ncx: 1000 },
  { file: 'file_00000000b280820ab886eb4cf8be8fa3.png', name: 'globe.jpeg',     label: 'Globe',      ncx: 5000 },
  { file: 'file_0000000095f081f490d301c0473200d4.png', name: 'stadium.jpeg',   label: 'Stadium',    ncx: 10000 },
];

async function uploadImage(localPath, remoteName) {
  const buffer = fs.readFileSync(localPath);

  // Upsert = delete then post (Storage v1 upsert header)
  const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${BUCKET}/${remoteName}`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${SERVICE_KEY}`,
      'Content-Type': 'image/jpeg',
      'Cache-Control': '3600',
      'x-upsert': 'true',
    },
    body: buffer,
  });

  const text = await res.text();
  const publicUrl = `${SUPABASE_URL}/storage/v1/object/public/${BUCKET}/${remoteName}`;
  if (res.ok || res.status === 200) {
    console.log(`✅  ${remoteName}  →  ${publicUrl}`);
    return { name: remoteName, url: publicUrl };
  } else {
    console.error(`❌  ${remoteName} FAILED (${res.status}): ${text}`);
    return null;
  }
}

async function main() {
  if (!SERVICE_KEY) {
    console.error('ERROR: Set SUPABASE_SERVICE_KEY env variable first.');
    console.error('  $env:SUPABASE_SERVICE_KEY="your-service-role-key"');
    process.exit(1);
  }

  console.log('🎁 Uploading gift icons to Supabase 3...\n');
  const results = [];

  for (const gift of GIFT_MAP) {
    const localPath = path.join(IMAGE_DIR, gift.file);
    if (!fs.existsSync(localPath)) {
      console.warn(`⚠️  Not found: ${gift.file}`);
      continue;
    }
    const result = await uploadImage(localPath, gift.name);
    if (result) results.push({ ...gift, url: result.url });
  }

  console.log('\n\n── Flutter gift_packs config ──────────────────────────────');
  console.log('// Paste this into lib/widgets/gift_overlay.dart or gift_packs config:\n');
  console.log('const List<Map<String, dynamic>> kGiftPacks = [');
  for (const g of results) {
    console.log(`  { 'id': '${g.name.replace('.jpeg','')}', 'label': '${g.label}', 'ncx': ${g.ncx}, 'imageUrl': '${g.url}' },`);
  }
  console.log('];');
}

main().catch(console.error);
