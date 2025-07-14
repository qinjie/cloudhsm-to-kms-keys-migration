#!/bin/bash

set -eo pipefail
export PATH=$PATH:/opt/cloudhsm/bin

# ".*" to match all labels, "^mvgx-*" to mach keys with label starting with `mvgx-`
label_pattern=".*"   

MAX_ITEMS=10
STARTING_TOKEN=""

echo "Counting keys matching pattern: $label_pattern"
echo "=========================================="

# Initialize counters
declare -A key_counts

while true; do
  # Build the base command
  CMD="cloudhsm-cli key list --max-items $MAX_ITEMS --verbose"
  if [ -n "$STARTING_TOKEN" ]; then
    CMD="$CMD --starting-token $STARTING_TOKEN"
  fi

  # Run the command and capture output
  OUTPUT=$($CMD)

  # Extract and process keys from current batch
  echo "$OUTPUT" | jq -c '.data.matched_keys[]' | while read -r key; do
    label=$(echo "$key" | jq -r '.attributes.label // ""')
    
    if [[ "$label" =~ $label_pattern ]]; then
      key_type=$(echo "$key" | jq -r '.attributes."key-type" // "unknown"')
      key_class=$(echo "$key" | jq -r '.attributes.class // "unknown"')
      
      # Create a composite key for counting
      count_key="${key_type}_${key_class}"
      
      # Increment counter (use a temporary file since we're in a subshell)
      echo "$count_key" >> /tmp/key_count_$$
    fi
  done

  # Get the next_token from the output
  NEXT_TOKEN=$(echo "$OUTPUT" | jq -r '.data.next_token // empty')

  # Stop if there is no next_token
  if [ -z "$NEXT_TOKEN" ]; then
    break
  fi

  STARTING_TOKEN="$NEXT_TOKEN"
done

# Process the temporary file to get counts
if [ -f "/tmp/key_count_$$" ]; then
  echo "Key Type        | Class       | Count"
  echo "----------------|-------------|-------"
  
  # Sort and count occurrences
  sort /tmp/key_count_$$ | uniq -c | while read count key_info; do
    key_type=$(echo "$key_info" | cut -d'_' -f1)
    key_class=$(echo "$key_info" | cut -d'_' -f2)
    printf "%-15s | %-11s | %d\n" "$key_type" "$key_class" "$count"
  done
  
  # Calculate and display total
  total_count=$(wc -l < /tmp/key_count_$$)
  echo "----------------|-------------|-------"
  printf "%-15s | %-11s | %d\n" "TOTAL" "" "$total_count"
  
  # Clean up
  rm /tmp/key_count_$$
else
  echo "No keys found matching pattern '$label_pattern'"
fi