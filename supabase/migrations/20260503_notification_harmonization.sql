-- ═══════════════════════════════════════════════════════════════════════════
-- NECXA PLATFORM – MIGRATION: Notification System Harmonization
-- File: 20260503_notification_harmonization.sql
-- Goal: Align Supabase notifications with Redis event flows.
-- ═══════════════════════════════════════════════════════════════════════════

-- 1. Relax the notification_type constraint and add social types
ALTER TABLE notifications DROP CONSTRAINT IF EXISTS notifications_notification_type_check;

-- 2. Add social and engine-specific columns
ALTER TABLE notifications 
  ADD COLUMN IF NOT EXISTS actor_id UUID REFERENCES profiles(id),
  ADD COLUMN IF NOT EXISTS target_id TEXT, -- Can be post_id, listing_id, etc.
  ADD COLUMN IF NOT EXISTS type TEXT;     -- Alias for notification_type (used by Redis)

-- 3. Create a trigger to keep 'type' and 'notification_type' in sync
CREATE OR REPLACE FUNCTION sync_notification_types()
RETURNS TRIGGER AS $$
BEGIN
    IF NEW.type IS NOT NULL AND NEW.notification_type IS NULL THEN
        NEW.notification_type = NEW.type;
    ELSIF NEW.notification_type IS NOT NULL AND NEW.type IS NULL THEN
        NEW.type = NEW.notification_type;
    END IF;
    
    -- Auto-generate title and body if missing (for smart social alerts)
    IF NEW.title IS NULL THEN
        NEW.title = CASE 
            WHEN NEW.type = 'like' THEN 'New Like!'
            WHEN NEW.type = 'comment' THEN 'New Comment!'
            WHEN NEW.type = 'follow' THEN 'New Follower!'
            WHEN NEW.type = 'save' THEN 'Post Saved'
            ELSE 'Necxa Alert'
        END;
    END IF;

    IF NEW.body IS NULL THEN
        NEW.body = CASE 
            WHEN NEW.type = 'like' THEN 'Someone loved your post.'
            WHEN NEW.type = 'comment' THEN 'Check out what they said on your content.'
            WHEN NEW.type = 'follow' THEN 'A new user joined your network.'
            WHEN NEW.type = 'save' THEN 'Your content was added to a collection.'
            ELSE 'Engagement on your profile.'
        END;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS tr_sync_notification_types ON notifications;
CREATE TRIGGER tr_sync_notification_types
    BEFORE INSERT ON notifications
    FOR EACH ROW EXECUTE FUNCTION sync_notification_types();

-- 4. Enable Realtime for the notifications table
ALTER PUBLICATION supabase_realtime ADD TABLE notifications;

-- 5. Add RLS policies for notifications (if not present)
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "Users can view own notifications" ON notifications;
CREATE POLICY "Users can view own notifications" 
    ON notifications FOR SELECT 
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update own notifications" ON notifications;
CREATE POLICY "Users can update own notifications" 
    ON notifications FOR UPDATE 
    USING (auth.uid() = user_id);

-- 6. Log the harmonization
INSERT INTO system_logs (category, message, metadata)
VALUES ('ENGAGEMENT', 'Notification system harmonized across Supabase and Redis.',
        '{"unified": true, "realtime": true}');
