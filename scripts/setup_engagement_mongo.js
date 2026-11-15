const engagement = db.getSiblingDB("necxa_engagement");

engagement.engagement_likes.createIndex(
  { entityType: 1, entityId: 1, userId: 1 },
  { unique: true, name: "unique_entity_like" },
);

engagement.engagement_comments.createIndex(
  { entityType: 1, entityId: 1, createdAt: -1 },
  { name: "entity_comments_recent" },
);
engagement.engagement_comments.createIndex(
  { entityType: 1, entityId: 1, userId: 1, idempotencyKey: 1 },
  {
    unique: true,
    name: "unique_entity_comment_request",
    partialFilterExpression: { idempotencyKey: { $type: "string" } },
  },
);
engagement.engagement_comments.createIndex(
  { sourceId: 1 },
  {
    unique: true,
    name: "unique_legacy_comment_source",
    partialFilterExpression: { sourceId: { $type: "string" } },
  },
);

engagement.engagement_totals.createIndex(
  { entityType: 1, entityId: 1 },
  { unique: true, name: "unique_entity_totals" },
);
engagement.engagement_migrations.createIndex(
  { key: 1 },
  { unique: true, name: "unique_engagement_migration" },
);

printjson({
  ok: 1,
  database: engagement.getName(),
  collections: engagement.getCollectionNames().sort(),
  documents: {
    likes: engagement.engagement_likes.countDocuments({}),
    comments: engagement.engagement_comments.countDocuments({}),
    totals: engagement.engagement_totals.countDocuments({}),
  },
});
