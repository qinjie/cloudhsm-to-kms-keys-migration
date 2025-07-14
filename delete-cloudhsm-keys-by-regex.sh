#!/bin/bash

set -eo pipefail

label_pattern="^mvgx-*"
MAX_ITEMS=10
STARTING_TOKEN=""

# First, collect all matching key labels with pagination
echo "Collecting all key labels matching pattern: $label_pattern"
all_key_labels=""

while true; do
  # Build the base command
  CMD="cloudhsm-cli key list --max-items $MAX_ITEMS --verbose"
  if [ -n "$STARTING_TOKEN" ]; then
    CMD="$CMD --starting-token $STARTING_TOKEN"
  fi

  # Run the command and capture output
  OUTPUT=$($CMD)

  # Extract labels from current batch and filter by pattern
  batch_labels=$(echo "$OUTPUT" | jq -r '.data.matched_keys[].attributes.label' | grep -E "$label_pattern" || true)
  
  if [ -n "$batch_labels" ]; then
    all_key_labels="$all_key_labels$batch_labels"$'\n'
  fi

  # Get the next_token from the output
  NEXT_TOKEN=$(echo "$OUTPUT" | jq -r '.data.next_token // empty')

  # Stop if there is no next_token
  if [ -z "$NEXT_TOKEN" ]; then
    break
  fi

  STARTING_TOKEN="$NEXT_TOKEN"
done

# Remove trailing newline and display found labels
key_labels=$(echo "$all_key_labels" | sed '/^$/d')

echo "$key_labels"

# Now delete keys for each matching label
while read -r label; do
	echo "Keys matching label: $label"

	matching_keys=$(cloudhsm-cli key list --filter attr.label="$label" --verbose | jq -r '.data.matched_keys[]."key-reference"')
	echo $matching_keys

	while read -r ref_key; do
		cloudhsm-cli key delete --filter key-reference="$ref_key"
	done <<< "$matching_keys"

done <<< "$key_labels"

