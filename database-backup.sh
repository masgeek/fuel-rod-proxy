#!/bin/bash


#set -o allexport; source /home/akilimo/services/tsobu-proxy/.env; set +o allexport

while [ $# -gt 0 ]; do
  case "$1" in
    -u|-user|--user)
      user="$2"
      ;;
    -p|-pass|--pass)
      pass="$2"
      ;;
    -s|-service|--service)
      service="$2"
      ;;
    -h|-host|--host)
      host="$2"
      ;;
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument.*\n"
      printf "***************************\n"
      exit 1
  esac
  shift
  shift
done

timestamp=$(date +%Y%m%d%H%M%S)


dbUser = ${user:-root}
dbPass = ${pass}
dbService = ${service:-maria}
dbHost = ${host:-127.0.0.1}

for T in `docker exec ${dbService} mysql -u ${dbUser} --password=${dbPass} -h ${dbHost} -N -B -e 'SHOW schemas;'`;
do

  case $T in
	information_schema|mysql|performance_schema|sys|test)
    echo "Skip backing up of $T schema"
		;;
	*)
        echo "Backing up $T"
        filename="${timestamp}-${DB_NAME}.sql"
        docker exec "${dbService}" mysqldump --no-tablespaces -u "${dbUser}" --password="${dbPass}" $T > $filename

        sed -i "db-backup/$filename" -e 's/utf8mb4_0900_ai_ci/utf8mb4_unicode_ci/g'
		;;
  esac
done;
