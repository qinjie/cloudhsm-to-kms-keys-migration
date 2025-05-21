label_pattern="^mvgx-*"

key_labels=$(cloudhsm-cli key list --max-items 100 --verbose | jq -r '.data.matched_keys[].attributes.label' | grep -E "$label_pattern")

echo $key_labels

while read -r label; do
	echo "Keys matching label: $label"

	matching_keys=$(cloudhsm-cli key list --filter attr.label="$label" --verbose | jq -r '.data.matched_keys[]."key-reference"')
	echo $matching_keys

	while read -r ref_key; do
		cloudhsm-cli key delete --filter key-reference="$ref_key"
	done <<< "$matching_keys"

done <<< "$key_labels"

