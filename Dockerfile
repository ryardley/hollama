FROM node:20-alpine AS builder
RUN corepack enable && corepack prepare pnpm@latest --activate
WORKDIR /app
COPY package.json package-lock.json ./
RUN pnpm import && pnpm install --frozen-lockfile
COPY . .
RUN pnpm run build

FROM caddy:2-alpine
COPY --from=builder /app/build /srv
EXPOSE 3000
CMD ["caddy", "file-server", "--root", "/srv", "--listen", ":3000"]
