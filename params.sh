#!/usr/bin/env bash

while [ $# -gt 0 ]; do
  case "$1" in
    -p|-p_out|--p_out)
      p_out="$2"
      ;;
    -a|-arg_1|--arg_1)
      arg_1="$2"
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
echo "p_out: ${p_out}"
echo "arg_1: ${arg_1}"
echo
echo "With default values:"
echo "p_out: ${p_out:-\"27\"}"
echo "arg_1: ${arg_1:-\"smarties cereal\"}"