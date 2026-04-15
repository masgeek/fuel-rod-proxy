FROM nginx:1.30-alpine

COPY infra/nginx/nginx.conf /etc/nginx/nginx.conf
