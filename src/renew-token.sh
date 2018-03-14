#!/usr/bin/env sh

set -eo pipefail

validateVaultResponse () {
  if echo ${2} | grep "errors"; then
    echo "ERROR: unable to retrieve ${1}: ${2}"
    exit 1
  fi
}

if [ -z ${RENEW_INTERVAL+x} ]; then RENEW_INTERVAL=21600; else echo "RENEW_INTERVAL is set to '${RENEW_INTERVAL}'"; fi

while true
do
    TOKEN_LOOKUP_RESPONSE=$(curl -sS \
      --header "X-Vault-Token: ${VAULT_TOKEN}" \
      ${VAULT_ADDR}/v1/auth/token/lookup-self | \
      jq -r 'if .errors then . else . end')
    validateVaultResponse 'token lookup' "${TOKEN_LOOKUP_RESPONSE}"

    CREATION_TTL=$(echo ${TOKEN_LOOKUP_RESPONSE} | jq -r '.data.creation_ttl')
    RENEWAL_TTL=$(expr ${CREATION_TTL} / 2)
    CURRENT_TTL=$(echo ${TOKEN_LOOKUP_RESPONSE} | jq -r '.data.ttl')

    # Only renew if the current ttl is below half the original ttl
    if [ ${CURRENT_TTL} -lt ${RENEWAL_TTL} ]; then
        echo "Renewing token from Vault server: ${VAULT_ADDR}"

        TOKEN_RENEW=$(curl -sS --request POST \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          ${VAULT_ADDR}/v1/auth/token/renew-self | \
          jq -r 'if .errors then . else .auth.client_token end')
        validateVaultResponse 'renew token' "${TOKEN_RENEW}"

        echo "Token renewed"
    else
        echo "Token not renewed, ttl: ${CURRENT_TTL}"
    fi

    #######################################################################

    # Renew secrets if they we have their lease ids

    lease_ids=$(echo ${LEASE_IDS} | tr "," "\n")

    for lease_id in $lease_ids
    do
        LEASE_LOOKUP_RESPONSE=$(curl -sS --request PUT \
          --header "X-Vault-Token: ${VAULT_TOKEN}" \
          ${VAULT_ADDR}/v1/sys/leases/lookup \
          -H "Content-Type: application/json" \
          -d '{"lease_id":"'"${lease_id}"'"}' | \
          jq -r 'if .errors then . else .data end')
        validateVaultResponse "lease lookup (${lease_id})" "${LEASE_LOOKUP_RESPONSE}"

        RENEWAL_TTL=$(expr ${RENEW_INTERVAL} \* 2)
        CURRENT_TTL=$(echo ${LEASE_LOOKUP_RESPONSE} | jq -r '.ttl')

        # Only renew if the current ttl is below twice the renew interval
        if [ ${CURRENT_TTL} -lt ${RENEWAL_TTL} ]; then
            echo "Renewing secret: ${lease_ids}"

            SECRET_RENEW=$(curl -sS --request PUT \
              --header "X-Vault-Token: ${VAULT_TOKEN}" \
              ${VAULT_ADDR}/v1/sys/leases/renew \
              -H "Content-Type: application/json" \
              -d '{"lease_id":"'"${lease_id}"'"}' | \
              jq -r 'if .errors then . else . end')
            validateVaultResponse "renew secret ($lease_id)" "${SECRET_RENEW}"

            echo "Secret renewed"
        else
            echo "Secret not renewed, ttl: ${CURRENT_TTL}"
        fi
    done

    sleep ${RENEW_INTERVAL}
done