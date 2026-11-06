const { randomBytes } = require("node:crypto");

for (const name of [
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
]) {
  if (!process.env[name]) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
}

const supabaseUrl = process.env.SUPABASE_URL.replace(/\/+$/, "");
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const suffix = randomBytes(10).toString("hex");
const password = `${randomBytes(24).toString("base64url")}aA1!`;
const createdUserIds = [];

async function requestJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  const body = text ? JSON.parse(text) : null;
  if (!response.ok) {
    const message = body?.message || body?.error || response.statusText;
    throw new Error(`${response.status} ${message}`);
  }
  return body;
}

function authHeaders(key) {
  return {
    apikey: key,
    Authorization: `Bearer ${key}`,
    "Content-Type": "application/json",
  };
}

async function createUser(role) {
  const user = await requestJson(`${supabaseUrl}/auth/v1/admin/users`, {
    method: "POST",
    headers: authHeaders(serviceRoleKey),
    body: JSON.stringify({
      email: `notification-${role}-${suffix}@example.com`,
      password,
      email_confirm: true,
    }),
  });
  createdUserIds.push(user.id);
  return user;
}

async function signIn(email) {
  return requestJson(
    `${supabaseUrl}/auth/v1/token?grant_type=password`,
    {
      method: "POST",
      headers: {
        apikey: anonKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ email, password }),
    },
  );
}

async function invoke(accessToken, action, payload = {}) {
  return requestJson(`${supabaseUrl}/functions/v1/clever-processor`, {
    method: "POST",
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${accessToken}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ action, payload }),
  });
}

async function cleanup() {
  for (const userId of createdUserIds.reverse()) {
    await fetch(`${supabaseUrl}/auth/v1/admin/users/${userId}`, {
      method: "DELETE",
      headers: authHeaders(serviceRoleKey),
    });
  }
}

async function main() {
  try {
    const [actor, recipient] = await Promise.all([
      createUser("actor"),
      createUser("recipient"),
    ]);
    const [actorSession, recipientSession] = await Promise.all([
      signIn(actor.email),
      signIn(recipient.email),
    ]);

    const triggered = await invoke(
      actorSession.access_token,
      "trigger-notification",
      {
        type: "follow",
        target_id: recipient.id,
        target_type: "profile",
      },
    );
    const notificationId = triggered.data?.id;
    if (!notificationId) throw new Error("Notification was not created");

    const firstInbox = await invoke(
      recipientSession.access_token,
      "fetch-notifications",
      { limit: 10 },
    );
    const notification = firstInbox.data?.find(
      (item) => item.id === notificationId,
    );
    if (!notification || notification.is_read) {
      throw new Error("Unread notification was not returned");
    }

    await invoke(recipientSession.access_token, "mark-notification-read", {
      notification_id: notificationId,
    });
    const secondInbox = await invoke(
      recipientSession.access_token,
      "fetch-notifications",
      { limit: 10 },
    );
    const updated = secondInbox.data?.find(
      (item) => item.id === notificationId,
    );
    if (!updated?.is_read) throw new Error("Read state did not synchronize");

    console.log(JSON.stringify({
      ok: true,
      created: true,
      fetched: true,
      readStateSynchronized: true,
    }, null, 2));
  } finally {
    await cleanup();
  }
}

main().catch((error) => {
  console.error(error.cause?.message || error.message);
  process.exitCode = 1;
});
