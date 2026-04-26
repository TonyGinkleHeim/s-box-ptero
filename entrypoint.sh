#!/bin/bash
cd /home/container || exit 1

INTERNAL_IP=$(ip route get 1 | awk '{print $(NF-2);exit}')
export INTERNAL_IP

# Replace {{VAR}} placeholders inside STARTUP with current env
PARSED=$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')
PARSED=$(eval echo "\"${PARSED}\"")

echo -e ":/home/container$ ${PARSED}"

# shellcheck disable=SC2086
exec ${PARSED}
