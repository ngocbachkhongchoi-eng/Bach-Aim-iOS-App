FROM node:24-alpine
WORKDIR /app
COPY package.json server.mjs ./
RUN mkdir /data && chown node:node /data
USER node
ENV HOST=0.0.0.0 PORT=8080 BIGVIP_DB=/data/bigvip.sqlite
EXPOSE 8080
CMD ["node", "server.mjs"]
