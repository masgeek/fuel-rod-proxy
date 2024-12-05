#!/bin/bash
# ./docker/supervisor/start.sh

# Create required directories
mkdir -p /var/log/supervisor

# Process PHP-FPM configuration
envsubst < /usr/local/etc/php-fpm.d/www.conf.template > /usr/local/etc/php-fpm.d/www.conf

# Process supervisor program configurations
for template in /etc/supervisor/conf.d/*.template; do
    if [ -f "$template" ]; then
        output_file="${template%.template}"
        envsubst < "$template" > "$output_file"
        rm "$template"
    fi
done

# Start supervisord
exec /usr/bin/supervisord -n -c /etc/supervisor/supervisord.conf
