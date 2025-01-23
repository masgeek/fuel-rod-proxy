
# Fuelrod docker compose

Docker compose tool for combining reverse proxy with docker containers to allow domain name serving

[NGINX Rate Limiting](https://www.nginx.com/blog/rate-limiting-nginx/#:~:text=Rate%20%E2%80%93%20Sets%20the%20maximum%20request,1%20request%20every%20100%20milliseconds)

### Certbot 

```shell
  sudo certbot --nginx -d munywele.co.ke
```


```shell
    docker run -d \
      --name dozzle \
      --restart unless-stopped \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -e DOZZLE_HOSTNAME='munywele.co.ke' \
      -p 9999:8080 \
      amir20/dozzle:latest
```

### Get WSL ip address

```shell
  ip addr show eth0
```