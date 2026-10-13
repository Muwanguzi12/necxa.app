const fs = require('fs');
const path = 'supabase/functions/smooth-action/index.ts';
let content = fs.readFileSync(path, 'utf8');

const target =   // Check already unlocked
  const { data: existing } = await supabase
    .from("unlocks")
    .select("id")
    .eq("property_id", propertyId)
    .eq("buyer_id", userId)
    .single()
  if (existing) return json({ success: true, already_unlocked: true, unlock_id: existing.id })

  const unlockAmount = Math.floor(property.price * 0.1)

  // Create unlock record
  const { data: unlock, error: unlockErr } = await supabase
    .from("unlocks")
    .insert({
      property_id: propertyId,
      buyer_id: userId,
      seller_id: property.lister_id,
      agent_id: property.agent_id,
      unlock_amount: unlockAmount,
      status: "completed",
      address_revealed_at: new Date().toISOString(),
      contact_revealed_at: new Date().toISOString(),
    })
    .select()
    .single()
  if (unlockErr) return err(\Unlock error: \\)

  // Increment unlocks count;

const replacement =   // Check already unlocked
  const { data: existing } = await supabase
    .from("unlocks")
    .select("id")
    .eq("property_id", propertyId)
    .eq("buyer_id", userId)
    .single()
  if (existing) return json({ success: true, already_unlocked: true, unlock_id: existing.id })

  const unlockAmount = Math.floor(property.price * 0.1)

  // Check free trial
  const { data: profile } = await supabase
    .from("profiles")
    .select("has_used_free_unlock")
    .eq("id", userId)
    .single()
    
  if (profile?.has_used_free_unlock) {
    return json({ success: false, requires_payment: true, unlock_cost: unlockAmount })
  }

  // Use Free Trial: Create unlock record
  const { data: unlock, error: unlockErr } = await supabase
    .from("unlocks")
    .insert({
      property_id: propertyId,
      buyer_id: userId,
      seller_id: property.lister_id,
      agent_id: property.agent_id,
      unlock_amount: 0,
      unlock_cost: unlockAmount,
      status: "completed",
      address_revealed_at: new Date().toISOString(),
      contact_revealed_at: new Date().toISOString(),
    })
    .select()
    .single()
  if (unlockErr) return err(\Unlock error: \\)

  // Mark trial as used
  await supabase.from("profiles").update({ has_used_free_unlock: true }).eq("id", userId)

  // Increment unlocks count;

content = content.replace(target, replacement);
fs.writeFileSync(path, content, 'utf8');
console.log('Done');
