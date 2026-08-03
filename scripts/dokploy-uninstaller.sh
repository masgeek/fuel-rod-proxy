#!/bin/bash
uninstall_dokploy() {
    if [ "$(id -u)" != "0" ]; then
        echo "This script must be run as root" >&2
        exit 1
    fi

    echo "WARNING: This will completely remove Dokploy, its services, secrets, networks, and volumes."
    read -p "Are you sure you want to uninstall Dokploy? (y/N): " confirm

    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Uninstall cancelled."
        exit 0
    fi

    echo "Uninstalling Dokploy..."

    # Leave swarm if active
    docker swarm leave --force 2>/dev/null

    # Remove Dokploy services
    docker service rm dokploy dokploy-postgres dokploy-redis 2>/dev/null

    # Remove Dokploy secrets
    docker secret rm dokploy_postgres_password 2>/dev/null

    # Remove Dokploy network
    docker network rm dokploy-network 2>/dev/null

    # Remove Dokploy volumes
    docker volume rm dokploy dokploy-postgres dokploy-redis 2>/dev/null

    # Remove Dokploy configs
    docker config rm $(docker config ls -q) 2>/dev/null

    # Remove Dokploy directory
    rm -rf /etc/dokploy

    echo "Cleaning up leftover containers..."
    docker rm -f $(docker ps -aq) 2>/dev/null

    echo "Cleaning up leftover networks..."
    docker network rm $(docker network ls -q) 2>/dev/null

    echo "Cleaning up leftover volumes..."
    docker volume rm $(docker volume ls -q) 2>/dev/null

    echo "Cleaning up leftover secrets..."
    docker secret rm $(docker secret ls -q) 2>/dev/null

    echo "Dokploy has been completely uninstalled."
    echo "Docker itself remains installed and ready for reuse."
}

uninstall_dokploy