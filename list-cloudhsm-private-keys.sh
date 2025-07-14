
#!/bin/bash

# Lists CloudHSM keys (private or public) matching a regex pattern on their labels.
# Paginates through all keys in CloudHSM, filters by configurable label pattern,
# and outputs results to labeled_keys.json as a proper JSON array.

set -eo pipefail
export PATH=$PATH:/opt/cloudhsm/bin

label_pattern=".*"  # ".*" to match all labels, "^mvgx-*" to mach keys with label starting with `mvgx-`
key_class="private-key"  # "private-key" or "public-key"
OUTPUT_FILE="private_keys.json"

MAX_ITEMS=10
STARTING_TOKEN=""
FIRST_RUN=true

echo "Searching for $key_class keys matching pattern: $label_pattern"

# Empty the output file before starting
> "$OUTPUT_FILE"

while true; do
  # Build the base command
  CMD="cloudhsm-cli key list --filter attr.class=$key_class --verbose --max-items $MAX_ITEMS"
  if [ -n "$STARTING_TOKEN" ]; then
    CMD="$CMD --starting-token $STARTING_TOKEN"
  fi

  # Run the command and capture output
  OUTPUT=$($CMD)

  # Filter keys by label pattern and save to file
  if $FIRST_RUN; then
    # For first run, create the initial structure with filtered keys
    echo "$OUTPUT" | jq --arg pattern "$label_pattern" '
      .data.matched_keys |= map(select(.attributes.label // "" | test($pattern)))
    ' > "$OUTPUT_FILE"
    FIRST_RUN=false
  else
    # For subsequent runs, append filtered keys to matched_keys array
    FILTERED_KEYS=$(echo "$OUTPUT" | jq --arg pattern "$label_pattern" '
      .data.matched_keys | map(select(.attributes.label // "" | test($pattern)))
    ')
    
    # Only update if there are filtered keys
    if [ "$(echo "$FILTERED_KEYS" | jq 'length')" -gt 0 ]; then
      jq --argjson new_keys "$FILTERED_KEYS" '.data.matched_keys += $new_keys' "$OUTPUT_FILE" > "$OUTPUT_FILE.tmp" && mv "$OUTPUT_FILE.tmp" "$OUTPUT_FILE"
    fi
  fi

  # Get the next_token from the output
  NEXT_TOKEN=$(echo "$OUTPUT" | jq -r '.data.next_token // empty')

  # Stop if there is no next_token
  if [ -z "$NEXT_TOKEN" ]; then
    break
  fi

  STARTING_TOKEN="$NEXT_TOKEN"
done

# Report results
KEY_COUNT=$(jq '.data.matched_keys | length' "$OUTPUT_FILE")
echo "Found $KEY_COUNT $key_class keys matching pattern '$label_pattern' saved to $OUTPUT_FILE"


