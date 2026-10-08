const fs = require('fs');
const path = require('path');

const replacements = {
    "lib/screens/creator_screen.dart": [
        ["JOIN ?", "JOIN 🚀"],
        ["? PRO", "💎 PRO"]
    ],
    "lib/screens/list_screen.dart": [
        ["Next: Face ID ?", "Next: Face ID 👤"],
        ["Next: Property Details ?", "Next: Property Details 🏠"],
        ["Next: Photos & Docs ?", "Next: Photos & Docs 📸"],
        ["Next: GPS Location ?", "Next: GPS Location 📍"],
        ["Next: Review & Submit ?", "Next: Review & Submit 🚀"],
        ["? Back to Home", "🏠 Back to Home"]
    ],
    "lib/screens/payment_screen.dart": [
        ["VIEW CREDENTIALS ?", "VIEW CREDENTIALS 🔓"],
        ["AUTHORIZE PAYMENT ?", "AUTHORIZE PAYMENT 💳"]
    ],
    "lib/screens/pro_media_editor_screen.dart": [
        ["? MediaEditor:", "❌ MediaEditor:"],
        ["FAST SYNC ?", "FAST SYNC ⚡"],
        ["Master File Ready! ?", "Master File Ready! 🎉"]
    ],
    "lib/widgets/agent_onboarding_overlay.dart": [
        ["? Agent verification submitted!", "✅ Agent verification submitted!"],
        ["Agree & Continue ?", "Agree & Continue 🚀"]
    ],
    "lib/widgets/checkout_container.dart": [
        ["? Payment confirmed", "🎉 Payment confirmed"]
    ],
    "lib/widgets/shield_capture_overlay.dart": [
        ["Continue ?", "Continue 🚀"]
    ],
    "lib/widgets/verification_screen.dart": [
        ["? Verified ", "✅ Verified 🟢"],
        ["? Face Verified", "👤 Face Verified"]
    ]
};

for (const [filepath, pairs] of Object.entries(replacements)) {
    if (fs.existsSync(filepath)) {
        let content = fs.readFileSync(filepath, 'utf-8');
        for (const [oldStr, newStr] of pairs) {
            content = content.replaceAll(oldStr, newStr);
        }
        fs.writeFileSync(filepath, content, 'utf-8');
        console.log(`Processed ${filepath}`);
    }
}
