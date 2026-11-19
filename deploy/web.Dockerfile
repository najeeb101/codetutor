# syntax=docker/dockerfile:1
# The Next.js web UI. Built in one stage; the run stage keeps only Next.js's standalone output
# (the files the server really loads), the static files and public/ (incl. Monaco for the browser).
# Node pinned to an exact version by digest (amd64 + arm64).

FROM node:24.22.0-slim@sha256:91acba91b842bec0bf7ea6f5e09c644c7ccad72c4996ed9616d861d1c7cd60d4 AS build
ENV NEXT_TELEMETRY_DISABLED=1
WORKDIR /web
# Packages first (own layer). `npm ci` installs exactly package-lock.json; its postinstall
# script copies Monaco into public/monaco.
COPY web/package.json web/package-lock.json ./
COPY web/scripts ./scripts
RUN npm ci
COPY web/ ./
# Next.js computes the /api rewrite in next.config.ts at BUILD time, so the API's address
# inside the compose network is baked in here (and also set at run time for server components).
ARG CODETUTOR_API_URL=http://api:8000
ENV CODETUTOR_API_URL=$CODETUTOR_API_URL
ARG CODETUTOR_DEMO_API_URL=http://demo-api:8000
ENV CODETUTOR_DEMO_API_URL=$CODETUTOR_DEMO_API_URL
RUN npm run build

FROM node:24.22.0-slim@sha256:91acba91b842bec0bf7ea6f5e09c644c7ccad72c4996ed9616d861d1c7cd60d4
ENV NODE_ENV=production NEXT_TELEMETRY_DISABLED=1 HOSTNAME=0.0.0.0 PORT=3000
WORKDIR /web
# output: "standalone" (next.config.ts) writes server.js and a trimmed node_modules; the static
# files and public/ are not part of it and are copied next to it, where server.js serves them.
COPY --from=build /web/.next/standalone ./
COPY --from=build /web/.next/static ./.next/static
COPY --from=build /web/public ./public
# The files stay owned by root; the server runs as the image's unprivileged `node` user.
USER node
EXPOSE 3000
CMD ["node", "server.js"]
