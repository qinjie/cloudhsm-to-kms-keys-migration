#!/bin/bash

OUTPUT_FILE="private_keys.json"
MAX_ITEMS=100    # You can adjust this for efficiency (max 1000, but 100 is safe)
STARTING_TOKEN=""
FIRST_RUN=true

# Empty the output file before starting
> "$OUTPUT_FILE"

while true; do
  # Build the base command
  CMD="cloudhsm-cli key list --filter attr.class=private-key --verbose --max-items $MAX_ITEMS"
  if [ -n "$STARTING_TOKEN" ]; then
    CMD="$CMD --starting-token $STARTING_TOKEN"
  fi

  # Run the command and capture output
  OUTPUT=$($CMD)

  # Append or write output to the file
  if $FIRST_RUN; then
    echo "$OUTPUT" > "$OUTPUT_FILE"
    FIRST_RUN=false
  else
    # Extract and append only the "matched_keys" array for subsequent batches
    echo "$OUTPUT" | jq '.data.matched_keys' >> "$OUTPUT_FILE"
  fi

  # Get the next_token from the output
  NEXT_TOKEN=$(echo "$OUTPUT" | jq -r '.data.next_token // empty')

  # Stop if there is no next_token
  if [ -z "$NEXT_TOKEN" ]; then
    break
  fi

  STARTING_TOKEN="$NEXT_TOKEN"
done

echo "All private keys saved to $OUTPUT_FILE"


