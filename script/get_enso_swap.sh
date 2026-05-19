#!/bin/bash

# Usage: get_enso_swap.sh <chain_id> <input_token> <output_token> <amount> <sender>
# Env:   ENSO_API_KEY must be set
# Returns: hex-encoded `abi.encodePacked(router, data)` for an Enso V2 swap.
#          First 20 bytes are the router (`tx.to`), rest is the calldata.

CHAIN_ID=$1
INPUT_TOKEN=$2
OUTPUT_TOKEN=$3
AMOUNT=$4
SENDER=$5

# Get route (single call — returns tx calldata directly)
ROUTE_RESPONSE=$(curl -s -X POST "https://api.enso.build/api/v1/shortcuts/route" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $ENSO_API_KEY" \
  -d "{
    \"chainId\": $CHAIN_ID,
    \"fromAddress\": \"$SENDER\",
    \"routingStrategy\": \"router\",
    \"tokenIn\": [\"$INPUT_TOKEN\"],
    \"tokenOut\": [\"$OUTPUT_TOKEN\"],
    \"amountIn\": [\"$AMOUNT\"],
    \"slippage\": \"100\"
  }")

# Extract tx.to and tx.data using sed
TX_TO=$(echo "$ROUTE_RESPONSE" | sed -n 's/.*"tx":{[^}]*"to":"\(0x[^"]*\)".*/\1/p')
TX_DATA=$(echo "$ROUTE_RESPONSE" | sed -n 's/.*"data":"\(0x[^"]*\)".*/\1/p')

if [ -z "$TX_TO" ] || [ -z "$TX_DATA" ]; then
  echo "Error: Failed to get route. Response: $ROUTE_RESPONSE" >&2
  exit 1
fi

# Output packed: router (20 bytes) || calldata
echo -n "${TX_TO}${TX_DATA:2}"
