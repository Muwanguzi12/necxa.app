-- Drop the unified trigger
DROP TRIGGER IF EXISTS tr_sync_identity_shard ON identity_shards;
DROP TRIGGER IF EXISTS tr_sync_utility_shard ON utility_shards;
DROP FUNCTION IF EXISTS sync_verification_to_profile();

-- Create Identity specific function
CREATE OR REPLACE FUNCTION sync_identity_to_profile()
RETURNS TRIGGER AS $body
BEGIN
    IF NEW.verified = TRUE AND NEW.fraud_risk = 'low' THEN
        UPDATE profiles 
        SET 
            nin_verified = TRUE,
            nin_verified_at = NOW(),
            nin_number = COALESCE(NEW.extracted_nin, profiles.nin_number),
            full_name = COALESCE(NEW.extracted_name, profiles.full_name)
        WHERE id = NEW.user_id;
        
        PERFORM increment_trust_score(NEW.user_id, 20, 'biometric_id_verified');
    END IF;
    RETURN NEW;
END;
$body LANGUAGE plpgsql SECURITY DEFINER;

-- Create Utility specific function
CREATE OR REPLACE FUNCTION sync_utility_to_profile()
RETURNS TRIGGER AS $body
BEGIN
    IF NEW.verified = TRUE THEN
        PERFORM increment_trust_score(NEW.user_id, 10, 'utility_proof_verified');
    END IF;
    RETURN NEW;
END;
$body LANGUAGE plpgsql SECURITY DEFINER;

-- Attach triggers to their respective tables safely
CREATE TRIGGER tr_sync_identity_shard AFTER INSERT OR UPDATE ON identity_shards FOR EACH ROW EXECUTE FUNCTION sync_identity_to_profile();
CREATE TRIGGER tr_sync_utility_shard AFTER INSERT OR UPDATE ON utility_shards FOR EACH ROW EXECUTE FUNCTION sync_utility_to_profile();
