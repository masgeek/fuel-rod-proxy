#!/bin/bash
# Generate pgbouncer userlist.txt from environment variables
# MD5 hash format: md5 + md5(password + username)

USERLIST_FILE="/etc/pgbouncer/userlist.txt"

# Clear existing file
> "$USERLIST_FILE"

# Add users from environment variables
# Format: DB_USERNAME and DB_PASSWORD for the main user
if [ -n "$DB_USERNAME" ] && [ -n "$DB_PASSWORD" ]; then
    HASH=$(echo -n "md5$(echo -n "${DB_PASSWORD}${DB_USERNAME}" | md5sum | awk '{print $1}')")
    echo "\"$DB_USERNAME\" \"$HASH\"" >> "$USERLIST_FILE"
fi

# Add postgres superuser if credentials provided
if [ -n "$POSTGRES_USER" ] && [ -n "$POSTGRES_PASSWORD" ]; then
    HASH=$(echo -n "md5$(echo -n "${POSTGRES_PASSWORD}${POSTGRES_USER}" | md5sum | awk '{print $1}')")
    echo "\"$POSTGRES_USER\" \"$HASH\"" >> "$USERLIST_FILE"
fi

chmod 600 "$USERLIST_FILE"
echo "Userlist generated at $USERLIST_FILE"