FROM nginx:1.31-alpine

COPY infra/nginx/nginx.conf /etc/nginx/nginx.conf
