#!/bin/bash

OUTPUT_FILE="public_keys.json"
MAX_ITEMS=100    # Adjust as needed
STARTING_TOKEN=""
FIRST_RUN=true

> "$OUTPUT_FILE"

while true; do
  CMD="cloudhsm-cli key list --filter attr.class=public-key --verbose --max-items $MAX_ITEMS"
  [ -n "$STARTING_TOKEN" ] && CMD="$CMD --starting-token $STARTING_TOKEN"

  OUTPUT=$($CMD)

  if $FIRST_RUN; then
    echo "$OUTPUT" > "$OUTPUT_FILE"
    FIRST_RUN=false
  else
    echo "$OUTPUT" | jq '.data.matched_keys' >> "$OUTPUT_FILE"
  fi

  NEXT_TOKEN=$(echo "$OUTPUT" | jq -r '.data.next_token // empty')
  [ -z "$NEXT_TOKEN" ] && break
  STARTING_TOKEN="$NEXT_TOKEN"
done

echo "All public keys saved to $OUTPUT_FILE"


