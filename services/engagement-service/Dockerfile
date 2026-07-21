FROM node:18-alpine
WORKDIR /usr/src/app
COPY package.json package-lock.json* ./
RUN npm install --production
COPY . .
RUN npm run build || true
EXPOSE 4001
CMD ["node", "dist/index.js"]
