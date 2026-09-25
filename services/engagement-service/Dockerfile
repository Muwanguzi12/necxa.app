# Multi-stage build: build in a full Node image, then copy artifacts into a slim runtime image

# Builder
FROM node:20 AS builder
WORKDIR /usr/src/app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build

# Runtime
FROM node:20-alpine AS runtime
WORKDIR /usr/src/app
ENV NODE_ENV=production
# do not hardcode secrets here; MONGO_URI should be provided at runtime via env
COPY package.json package-lock.json* ./
RUN npm ci --omit=dev --no-audit --no-fund
COPY --from=builder /usr/src/app/dist ./dist
EXPOSE 4001
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD node -e "fetch('http://127.0.0.1:4001/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "dist/index.js"]
