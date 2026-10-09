FROM node:20-alpine
WORKDIR /app
COPY server.js index.html ./
ENV PORT=3102
EXPOSE 3102
CMD ["node", "server.js"]
