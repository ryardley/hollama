# ── Build stage ──────────────────────────────────────────────
FROM node:20-alpine AS builder

WORKDIR /app

# Copy package files first (layer caching)
COPY package*.json ./

# Install deps + add adapter-static (not in the default package.json)
RUN npm ci && npm i -D @sveltejs/adapter-static

# Copy everything else (.dockerignore handles exclusions)
COPY . .

# Override svelte.config.js to use adapter-static for a fully static SPA build.
# The fallback page makes client-side routing work for all paths.
RUN cat > svelte.config.js << 'SVELTECONFIG'
import adapter from '@sveltejs/adapter-static';
import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/** @type {import('@sveltejs/kit').Config} */
const config = {
	preprocess: vitePreprocess(),
	kit: {
		adapter: adapter({
			pages: 'build',
			assets: 'build',
			fallback: 'index.html',   // SPA fallback for client-side routing
			precompress: true,         // generate .br and .gz files
			strict: false
		})
	}
};

export default config;
SVELTECONFIG

# SvelteKit adapter-static needs every route to opt into prerendering or
# have a SPA fallback.  Set the layout default so all routes are covered.
RUN mkdir -p src/routes && \
    if ! grep -q 'prerender' src/routes/+layout.ts 2>/dev/null; then \
      echo 'export const prerender = true;'  >> src/routes/+layout.ts; \
      echo 'export const ssr = false;'       >> src/routes/+layout.ts; \
    fi

# Build the static site
RUN npm run build


# ── Runtime stage ────────────────────────────────────────────
FROM caddy:2-alpine

# Create non-root user
RUN addgroup -S appgroup && adduser -S appuser -G appgroup

# Inline Caddyfile
RUN cat > /etc/caddy/Caddyfile << 'CADDYFILE'
:8080 {
	root * /srv
	encode {
		gzip
		zstd
	}
	file_server {
		precompressed br gzip
	}
	try_files {path} /index.html
	header {
		X-Content-Type-Options    nosniff
		X-Frame-Options           DENY
		Referrer-Policy           strict-origin-when-cross-origin
		-Server
	}
	@immutable path /_app/*
	header @immutable Cache-Control "public, max-age=31536000, immutable"
	@html path /
	header @html Cache-Control "public, max-age=0, must-revalidate"
}
CADDYFILE

# Copy static build output (including precompressed .br/.gz files)
COPY --from=builder --chown=appuser:appgroup /app/build /srv

EXPOSE 8080

# Caddy runs as root by default to bind ports, but 8080 is unprivileged
USER appuser

CMD ["caddy", "run", "--config", "/etc/caddy/Caddyfile", "--adapter", "caddyfile"]
