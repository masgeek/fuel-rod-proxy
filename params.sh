#!/bin/bash

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
    *)
      printf "***************************\n"
      printf "* Error: Invalid argument.*\n"
      printf "***************************\n"
      exit 1
  esac
  shift
  shift
done

echo "Without default values:"
echo "password: ${pass}"
echo "username: ${user}"
echo "service: ${service}"
echo
echo "With default values:"
echo "password: ${pass:-\"27\"}"
echo "username: ${user:-\"smarties cereal\"}"


for T in `docker exec maria mysql -u ${user} --password=${pass} -h 127.0.0.1 -N -B -e 'SHOW schemas;'`;
do

if [ $T="information_schema" ];
then
    echo "Skip backing up of $T schema"
else
    echo "Backing up $T"
    # mysqldump --skip-comments --compact -u [USER] -p[PASSWORD] [DATABASE] $T > $T.sql

    #docker exec "${service}" mysqldump --no-tablespaces -u "${user}" --password="${pass}" $T >$T.sql
fi
done;





#docker exec maria mysqldump --no-tablespaces -u root --password=fuelrod akilimo_portal > akilimo_portal.

#docker exec maria mysql -u fuelrod --password=fuelrod -h 127.0.0.1 -N -B -e 'show schemas;'
