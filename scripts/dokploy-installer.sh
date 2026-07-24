#!/bin/bash
install_dokploy() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    if [ "$(uname)" = "Darwin" ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    if [ -f /.dockerenv ]; then
        echo "This script must be run on Linux" >&2
        exit 1
    fi

    if ss -tulnp | grep ':3000 ' >/dev/null; then
        echo "Error: something is already running on port 3000" >&2
        echo "Dokploy requires port 3000 to be available. Please stop any service using this port." >&2
        exit 1
    fi

    command_exists() {
      command -v "$@" > /dev/null 2>&1
    }

    if command_exists docker; then
      echo "Docker already installed"
    else
      curl -sSL https://get.docker.com | sh
    fi

    docker swarm leave --force 2>/dev/null

    get_ip() {
        local ip=""
        ip=$(curl -4s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -4s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -4s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -6s --connect-timeout 5 https://ifconfig.io 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -6s --connect-timeout 5 https://icanhazip.com 2>/dev/null)
        [ -z "$ip" ] && ip=$(curl -6s --connect-timeout 5 https://ipecho.net/plain 2>/dev/null)

        # Fallback: no outbound curl worked (e.g. WSL/local network with no
        # public IP lookup available) - use the local route's source IP instead.
        if [ -z "$ip" ]; then
            ip=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
        fi

        if [ -z "$ip" ]; then
            echo "Error: Could not determine server IP address automatically." >&2
            exit 1
        fi
        echo "$ip"
    }

    advertise_addr="${ADVERTISE_ADDR:-$(get_ip)}"
    echo "Using advertise address: $advertise_addr"

    docker swarm init --advertise-addr $advertise_addr || {
        echo "Error: Failed to initialize Docker Swarm" >&2
        exit 1
    }

    echo "Swarm initialized"

    docker network rm -f dokploy-network 2>/dev/null
    docker network create --driver overlay --attachable dokploy-network

    echo "Network created"

    mkdir -p /etc/dokploy
    chmod 777 /etc/dokploy

    POSTGRES_PASSWORD=$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-32)
    echo "$POSTGRES_PASSWORD" | docker secret create dokploy_postgres_password - 2>/dev/null || true
    echo "Generated secure database credentials (stored in Docker Secrets)"

    docker service create \
    --name dokploy-postgres \
    --constraint 'node.role==manager' \
    --network dokploy-network \
    --env POSTGRES_USER=dokploy \
    --env POSTGRES_DB=dokploy \
    --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
    --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data \
    postgres:17

    docker service create \
    --name dokploy-redis \
    --constraint 'node.role==manager' \
    --network dokploy-network \
    --mount type=volume,source=dokploy-redis,target=/data \
    redis:8

    docker service create \
      --name dokploy \
      --replicas 1 \
      --network dokploy-network \
      --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
      --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
      --mount type=volume,source=dokploy,target=/root/.docker \
      --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
      --publish published=3000,target=3000,mode=host \
      --update-parallelism 1 \
      --update-order stop-first \
      --constraint 'node.role == manager' \
      -e ADVERTISE_ADDR=$advertise_addr \
      -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
      dokploy/dokploy:latest

    GREEN="\033[0;32m"
    YELLOW="\033[1;33m"
    BLUE="\033[0;34m"
    NC="\033[0m"

    format_ip_for_url() {
        local ip="$1"
        if echo "$ip" | grep -q ':'; then
            echo "[${ip}]"
        else
            echo "${ip}"
        fi
    }

    formatted_addr=$(format_ip_for_url "$advertise_addr")
    echo ""
    printf "${GREEN}Congratulations, Dokploy is installed without Traefik!${NC}\n"
    printf "${BLUE}Wait 15 seconds for the server to start${NC}\n"
    printf "${YELLOW}Please go to http://${formatted_addr}:3000${NC}\n\n"
}

update_dokploy() {
    echo "Updating Dokploy..."
    docker pull dokploy/dokploy:latest
    docker service update --image dokploy/dokploy:latest dokploy
    echo "Dokploy has been updated to the latest version."
}

if [ "$1" = "update" ]; then
    update_dokploy
else
    install_dokploy
fi