#!/bin/sh
# Generates the S3 auth config (/etc/seaweedfs/s3.json) from environment
# variables, then execs the real seaweedfs command (passed as arguments).
# This lets secrets live in the compose environment instead of a repo file.
#
# Required: S3_ACCESS_KEY, S3_SECRET_KEY
# Optional: S3_READONLY_ACCESS_KEY, S3_READONLY_SECRET_KEY (adds a Read/List user)
set -eu

{
  printf '{\n'
  printf '  "defaultEffect": "Deny",\n'
  printf '  "identities": [\n'
  printf '    {\n'
  printf '      "name": "admin",\n'
  printf '      "credentials": [\n'
  printf '        {\n'
  printf '          "accessKey": "%s",\n' "${S3_ACCESS_KEY:?S3_ACCESS_KEY must be set}"
  printf '          "secretKey": "%s"\n' "${S3_SECRET_KEY:?S3_SECRET_KEY must be set}"
  printf '        }\n'
  printf '      ],\n'
  printf '      "actions": ["Admin", "Read", "Write", "List", "Tagging"]\n'
  printf '    }\n'

  if [ -n "${S3_READONLY_ACCESS_KEY:-}" ] && [ -n "${S3_READONLY_SECRET_KEY:-}" ]; then
    printf '    ,\n'
    printf '    {\n'
    printf '      "name": "readonly",\n'
    printf '      "credentials": [\n'
    printf '        {\n'
    printf '          "accessKey": "%s",\n' "${S3_READONLY_ACCESS_KEY}"
    printf '          "secretKey": "%s"\n' "${S3_READONLY_SECRET_KEY}"
    printf '        }\n'
    printf '      ],\n'
    printf '      "actions": ["Read", "List"]\n'
    printf '    }\n'
  fi

  printf '  ]\n'
  printf '}\n'
} > /etc/seaweedfs/s3.json

exec weed "$@"
