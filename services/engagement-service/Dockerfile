# Multi-stage build: build in a full Node image, then copy artifacts into a slim runtime image

# Builder
FROM node:18 AS builder
WORKDIR /usr/src/app
COPY package.json package-lock.json* ./
RUN npm ci
COPY . .
RUN npm run build

# Runtime
FROM node:18-alpine AS runtime
WORKDIR /usr/src/app
ENV NODE_ENV=production
# do not hardcode secrets here; MONGO_URI should be provided at runtime via env
COPY package.json package-lock.json* ./
RUN npm install --production
COPY --from=builder /usr/src/app/dist ./dist
EXPOSE 4001
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s CMD node -e "(async ()=>{try{const r=await require('./dist/index.js').default; console.log('ok'); process.exit(0);}catch(e){console.error('hc-fail',e); process.exit(1)}})()" || exit 1
CMD ["node", "dist/index.js"]
