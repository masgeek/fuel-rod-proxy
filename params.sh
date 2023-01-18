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
echo "service: ${service}"
echo
echo "With default values:"
echo "password: ${pass:-\"27\"}"
echo "username: ${user:-\"smarties cereal\"}"


for T in `docker exec ${service:-db} mysql -u ${user:-root} --password=${pass:-pass} -h 127.0.0.1 -N -B -e 'SHOW schemas;'`;
do

  case $T in
	information_schema|mysql|performance_schema|sys|test)
    echo "Skip backing up of $T schema"
		;;
	*)
        echo "Backing up $T"
        docker exec "${service}" mysqldump --no-tablespaces -u "${user}" --password="${pass}" $T >$T.sql
		;;
  esac
done;