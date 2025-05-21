for i in {1..20}; do
	cloudhsm-cli key generate-asymmetric-pair ec \
		--public-label "mvgx-pub-$i" \
		--private-label "mvgx-priv-$i" \
		--curve secp256k1 \
		--public-attributes encrypt=true verify=true \
		--private-attributes decrypt=true sign=true 
done

