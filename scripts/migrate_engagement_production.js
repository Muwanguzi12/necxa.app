const { randomBytes } = require("node:crypto");

const requiredEnv = [
  "SUPABASE_URL",
  "SUPABASE_ANON_KEY",
  "SUPABASE_SERVICE_ROLE_KEY",
];

for (const name of requiredEnv) {
  if (!process.env[name]) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
}

const supabaseUrl = process.env.SUPABASE_URL.replace(/\/+$/, "");
const anonKey = process.env.SUPABASE_ANON_KEY;
const serviceRoleKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
const shouldMigrate = process.argv.includes("--migrate");
const shouldDiagnose = process.argv.includes("--diagnose");
const shouldMigrateDirect = process.argv.includes("--direct");

async function requestJson(url, options = {}) {
  const response = await fetch(url, options);
  const text = await response.text();
  let body;
  try {
    body = text ? JSON.parse(text) : null;
  } catch {
    body = { raw: text };
  }
  if (!response.ok) {
    const message = body?.message || body?.error || body?.raw || response.statusText;
    const diagnostic = body?.diagnostic
      ? ` ${JSON.stringify(body.diagnostic)}`
      : "";
    throw new Error(`${response.status} ${message}${diagnostic}`);
  }
  return body;
}

async function restRows(table, select) {
  const url = new URL(`${supabaseUrl}/rest/v1/${table}`);
  url.searchParams.set("select", select);
  return requestJson(url, {
    headers: {
      apikey: serviceRoleKey,
      Authorization: `Bearer ${serviceRoleKey}`,
    },
  });
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

async function loadLegacyEngagement() {
  const [legacyLikes, legacyComments, linkedPosts] = await Promise.all([
    restRows("community_likes", "*"),
    restRows("community_comments", "*"),
    restRows("community_posts", "id,listing_id"),
  ]);
  const listingByPost = new Map(
    linkedPosts
      .filter((post) => post.listing_id)
      .map((post) => [String(post.id), String(post.listing_id)]),
  );
  const targetForPost = (postId) => {
    const listingId = listingByPost.get(String(postId));
    return listingId
      ? { entityType: "product", entityId: listingId }
      : { entityType: "post", entityId: String(postId) };
  };
  const likes = legacyLikes
    .filter((like) => like.post_id && like.user_id)
    .map((like) => ({
      ...targetForPost(like.post_id),
      userId: String(like.user_id),
      createdAt: like.created_at,
    }));
  const comments = legacyComments
    .filter(
      (comment) =>
        comment.id &&
        comment.post_id &&
        (comment.user_id || comment.author_id) &&
        comment.content,
    )
    .map((comment) => ({
      ...targetForPost(comment.post_id),
      userId: String(comment.user_id || comment.author_id),
      text: String(comment.content),
      sourceId: `supabase:${comment.id}`,
      createdAt: comment.created_at,
    }));
  return { likes, comments };
}

async function migrateDirectly() {
  if (!process.env.MONGO_URI) {
    throw new Error("MONGO_URI is required for --direct");
  }
  const { MongoClient } = require("mongodb");
  const client = new MongoClient(process.env.MONGO_URI, {
    appName: "necxa-engagement-migration",
    family: 4,
    connectTimeoutMS: 10_000,
    serverSelectionTimeoutMS: 10_000,
    retryReads: true,
    retryWrites: true,
  });

  try {
    const legacy = await loadLegacyEngagement();
    await client.connect();
    const database = client.db("necxa_engagement");
    const likes = database.collection("engagement_likes");
    const comments = database.collection("engagement_comments");
    const totals = database.collection("engagement_totals");
    const migrations = database.collection("engagement_migrations");

    await Promise.all([
      likes.createIndex(
        { entityType: 1, entityId: 1, userId: 1 },
        { unique: true, name: "unique_entity_like" },
      ),
      comments.createIndex(
        { entityType: 1, entityId: 1, userId: 1, idempotencyKey: 1 },
        {
          unique: true,
          name: "unique_entity_comment_request",
          partialFilterExpression: { idempotencyKey: { $type: "string" } },
        },
      ),
      comments.createIndex(
        { sourceId: 1 },
        {
          unique: true,
          name: "unique_legacy_comment_source",
          partialFilterExpression: { sourceId: { $type: "string" } },
        },
      ),
      totals.createIndex(
        { entityType: 1, entityId: 1 },
        { unique: true, name: "unique_entity_totals" },
      ),
      migrations.createIndex(
        { key: 1 },
        { unique: true, name: "unique_engagement_migration" },
      ),
    ]);

    if (legacy.likes.length > 0) {
      await likes.bulkWrite(
        legacy.likes.map((like) => ({
          updateOne: {
            filter: {
              entityType: like.entityType,
              entityId: like.entityId,
              userId: like.userId,
            },
            update: {
              $setOnInsert: {
                entityType: like.entityType,
                entityId: like.entityId,
                userId: like.userId,
                createdAt: like.createdAt ? new Date(like.createdAt) : new Date(),
              },
            },
            upsert: true,
          },
        })),
        { ordered: false },
      );
    }
    if (legacy.comments.length > 0) {
      await comments.bulkWrite(
        legacy.comments.map((comment) => ({
          updateOne: {
            filter: { sourceId: comment.sourceId },
            update: {
              $setOnInsert: {
                entityType: comment.entityType,
                entityId: comment.entityId,
                userId: comment.userId,
                text: comment.text,
                sourceId: comment.sourceId,
                createdAt: comment.createdAt
                  ? new Date(comment.createdAt)
                  : new Date(),
              },
            },
            upsert: true,
          },
        })),
        { ordered: false },
      );
    }

    const affected = new Map();
    for (const item of [...legacy.likes, ...legacy.comments]) {
      affected.set(`${item.entityType}:${item.entityId}`, {
        entityType: item.entityType,
        entityId: item.entityId,
      });
    }
    let verifiedLikes = 0;
    let verifiedComments = 0;
    for (const entity of affected.values()) {
      const filter = {
        entityType: entity.entityType,
        entityId: entity.entityId,
      };
      const [likesCount, commentsCount] = await Promise.all([
        likes.countDocuments(filter),
        comments.countDocuments(filter),
      ]);
      verifiedLikes += likesCount;
      verifiedComments += commentsCount;
      await totals.updateOne(
        filter,
        {
          $set: {
            ...filter,
            likes: likesCount,
            comments: commentsCount,
            updatedAt: new Date(),
          },
          $setOnInsert: { views: 0, createdAt: new Date() },
        },
        { upsert: true },
      );
    }
    await migrations.updateOne(
      { key: "supabase-community-v1" },
      {
        $set: {
          key: "supabase-community-v1",
          likesProcessed: legacy.likes.length,
          commentsProcessed: legacy.comments.length,
          completedAt: new Date(),
        },
      },
      { upsert: true },
    );

    const expectedLikes = new Set(
      legacy.likes.map(
        (like) => `${like.entityType}:${like.entityId}:${like.userId}`,
      ),
    ).size;
    if (
      verifiedLikes < expectedLikes ||
      verifiedComments < legacy.comments.length
    ) {
      throw new Error("Direct migration verification count mismatch");
    }
    console.log(
      JSON.stringify(
        {
          ok: true,
          mode: "direct",
          migration: {
            likesProcessed: legacy.likes.length,
            commentsProcessed: legacy.comments.length,
            entitiesRecounted: affected.size,
          },
          verified: {
            likes: verifiedLikes,
            comments: verifiedComments,
          },
        },
        null,
        2,
      ),
    );
  } finally {
    await client.close();
  }
}

async function main() {
  if (shouldMigrateDirect) {
    await migrateDirectly();
    return;
  }

  const suffix = randomBytes(8).toString("hex");
  const email = `engagement-smoke-${suffix}@example.com`;
  const password = `N3cxa-${randomBytes(18).toString("base64url")}!`;
  let temporaryUserId;

  try {
    const createdUser = await requestJson(`${supabaseUrl}/auth/v1/admin/users`, {
      method: "POST",
      headers: {
        apikey: serviceRoleKey,
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        email,
        password,
        email_confirm: true,
        app_metadata: { role: "admin", is_admin: true },
      }),
    });
    temporaryUserId = createdUser.id;

    const session = await requestJson(
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

    if (shouldDiagnose) {
      const diagnosis = await invoke(
        session.access_token,
        "diagnose-engagement",
      );
      console.log(JSON.stringify(diagnosis, null, 2));
      return;
    }

    const smokeEntityId = `production-smoke-${Date.now()}`;
    const smoke = await invoke(session.access_token, "fetch-engagement", {
      entities: [
        {
          id: smokeEntityId,
          local_id: smokeEntityId,
          target_type: "post",
        },
      ],
    });
    if (
      smoke.success !== true ||
      smoke.source !== "mongodb" ||
      !Array.isArray(smoke.data)
    ) {
      throw new Error("Production MongoDB engagement smoke test failed");
    }

    if (!shouldMigrate) {
      console.log(JSON.stringify({ ok: true, smoke: "mongodb-ready" }, null, 2));
      return;
    }

    const legacy = await loadLegacyEngagement();

    const expectedLikes = new Set();
    const expectedComments = [];
    const entitiesByKey = new Map();
    for (const like of legacy.likes) {
      const target = {
        id: like.entityId,
        target_type: like.entityType === "product" ? "listing" : "post",
      };
      expectedLikes.add(
        `${target.target_type}:${target.id}:${like.userId}`,
      );
      entitiesByKey.set(`${target.target_type}:${target.id}`, target);
    }
    for (const comment of legacy.comments) {
      const target = {
        id: comment.entityId,
        target_type: comment.entityType === "product" ? "listing" : "post",
      };
      expectedComments.push(comment.sourceId);
      entitiesByKey.set(`${target.target_type}:${target.id}`, target);
    }

    const migration = await invoke(
      session.access_token,
      "migrate-legacy-engagement",
    );
    if (migration.success !== true) {
      throw new Error("Legacy engagement migration was not accepted");
    }

    const entities = [...entitiesByKey.values()].map((entity) => ({
      ...entity,
      local_id: `${entity.target_type}:${entity.id}`,
    }));
    let migratedLikes = 0;
    let migratedComments = 0;
    for (let offset = 0; offset < entities.length; offset += 12) {
      const verification = await invoke(session.access_token, "fetch-engagement", {
        entities: entities.slice(offset, offset + 12),
      });
      if (verification.success !== true || !Array.isArray(verification.data)) {
        throw new Error("Post-migration engagement verification failed");
      }
      for (const row of verification.data) {
        migratedLikes += Number(row.likes_count || 0);
        migratedComments += Number(row.comments_count || 0);
      }
    }

    if (
      migratedLikes < expectedLikes.size ||
      migratedComments < expectedComments.length
    ) {
      throw new Error(
        `Migration count mismatch: expected at least ${expectedLikes.size} likes and ` +
          `${expectedComments.length} comments, found ${migratedLikes} likes and ` +
          `${migratedComments} comments`,
      );
    }

    console.log(
      JSON.stringify(
        {
          ok: true,
          smoke: "mongodb-ready",
          migration: migration.data,
          verified: {
            entities: entities.length,
            likes: migratedLikes,
            comments: migratedComments,
          },
        },
        null,
        2,
      ),
    );
  } finally {
    if (temporaryUserId) {
      await requestJson(
        `${supabaseUrl}/auth/v1/admin/users/${temporaryUserId}`,
        {
          method: "DELETE",
          headers: {
            apikey: serviceRoleKey,
            Authorization: `Bearer ${serviceRoleKey}`,
          },
        },
      ).catch((error) => {
        console.error(`Temporary user cleanup failed: ${error.message}`);
      });
    }
  }
}

main().catch((error) => {
  const cause = error.cause?.message ? `: ${error.cause.message}` : "";
  console.error(`${error.message}${cause}`);
  process.exitCode = 1;
});
