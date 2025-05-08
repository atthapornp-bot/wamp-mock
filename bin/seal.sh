#!/bin/bash

if ! which kubeseal > /dev/null; then
  echo "[$(date)] ERROR: kubeseal command not found, see https://github.com/bitnami-labs/sealed-secrets#linux"
  exit 1
fi

cd $(dirname $0)

for _SECRET in ${1:-unsealed-secrets/*.yaml}; do
  echo "[$(date)] Sealing ${_SECRET} to sealed-secrets/ ..."
  kubeseal -f ${_SECRET} -w sealed-secrets/$(basename ${_SECRET})
done
