FROM node:22-bookworm-slim
WORKDIR /app
COPY package.json ./
COPY . .
RUN npm install --omit=dev --no-audit --no-fund && npm install --global rea-agents@6.9.0
ENV NODE_ENV=production
EXPOSE 8787
CMD ["npm", "start"]
