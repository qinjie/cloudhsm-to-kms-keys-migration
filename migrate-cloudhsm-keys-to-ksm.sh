#!/bin/bash
set -eo pipefail

export PATH=$PATH:/opt/cloudhsm/bin

# CloudHSM config
PRIVATE_KEYS_FILE="private_keys.json"
PUBLIC_KEYS_FILE="public_keys.json"

# RSA keys need compatible wrapping algorithms
WRAPPING_ALGORITHM="RSAES_OAEP_SHA_256"
KEY_ALGORITHM="RSA_2048"

# Setup result files
echo "CloudHSM_KEY_REF,CLOUDHSM_KEY_LABEL" > result_keys_failed.txt
echo "CloudHSM_KEY_REF,CLOUDHSM_KEY_LABEL,KMS_KEY_ID" > result_keys_successful.txt

# Process each private key
jq -c '.data.matched_keys[]' $PRIVATE_KEYS_FILE | while read -r KEY; do
    # Extract key details
    echo $KEY
    # KEY_REF: Private key key-reference value
    KEY_REF=$(echo $KEY | jq -r '."key-reference"')
    # KEY_LABEL: Private key attributes.label value
    KEY_LABEL=$(echo $KEY | jq -r '.attributes.label')
    # EC_POINT: Private key attribute.ec-point value, which will be used to find respective public key key-reference
    KEY_EC_POINT=$(echo $KEY | jq -r '.attributes.["ec-point"]')

    # Sample values for TESTING
    # KEY_REF=0x0000000000040da2
    # KEY_LABEL=mvgx-priv-20
    # KEY_EC_POINT=0x044104cc8327248f84632cedddb20044b23974b8d19d9cb116c0803e3d4ada4dfeeeb09c6b338bbaeb7d640409a1f368b946c4b32230d14ff154b5afb551b5451bafff

    echo "Processing key: $KEY_LABEL, $KEY_REF, $KEY_EC_POINT"
    
    # Step 1: Create KMS key for RSA_2048
    # Keys with curve `secp256k1` must use wrapping key `ECC_SECG_P256K1`.
    # Keys with curve `prime256v1` must use wrapping key `ECC_NIST_P256`.
    KMS_KEY_ID=$(aws kms create-key --origin EXTERNAL --key-spec ECC_SECG_P256K1 --key-usage SIGN_VERIFY \
        --description "Imported from CloudHSM: $KEY_LABEL" \
        --query 'KeyMetadata.KeyId' --output text)
    echo "Created KMS key: $KMS_KEY_ID"

    # Step 2: Get wrapping parameters and save to named files
    WRAPPING_PUBLIC_KEY_B64="${KEY_REF}_WrappingPublicKey.b64"
    WRAPPING_PUBLIC_KEY_BIN="${KEY_REF}_WrappingPublicKey.bin"
    WRAPPING_PUBLIC_KEY_PEM="${KEY_REF}_WrappingPublicKey.pem"
    IMPORT_TOKEN_B64="${KEY_REF}_ImportToken.b64"
    IMPORT_TOKEN_BIN="${KEY_REF}_ImportToken.bin"
    
    # Save wrapping key parameters to files
    aws kms get-parameters-for-import \
        --key-id "$KMS_KEY_ID" \
        --wrapping-algorithm RSAES_OAEP_SHA_256 \
        --wrapping-key-spec RSA_4096 \
        --query "[ImportToken, PublicKey]" \
        --output text \
        | awk '{print $1 > "'$IMPORT_TOKEN_B64'"; print $2 > "'$WRAPPING_PUBLIC_KEY_B64'"}'

    echo "Saved wrapping parameters to $WRAPPING_PUBLIC_KEY_B64 and $IMPORT_TOKEN_B64"

    # decode the token from base64 to binary format before it can be used
    openssl enc -d -base64 -A -in $IMPORT_TOKEN_B64 -out $IMPORT_TOKEN_BIN    

    # Decode the base64 encoding to binary DER format
    openssl enc -d -base64 -A -in $WRAPPING_PUBLIC_KEY_B64 -out $WRAPPING_PUBLIC_KEY_BIN
    
    # Convert the wrapping public key from DER to PEM format
    openssl rsa -pubin -in $WRAPPING_PUBLIC_KEY_BIN -inform DER -outform PEM -out $WRAPPING_PUBLIC_KEY_PEM
    
    echo "Converted wrapping key to PEM format: $WRAPPING_PUBLIC_KEY_PEM"

    # Step 3: Import wrapping key to CloudHSM
    WRAP_LABEL="kms_wrapping_key_for_${KEY_REF}"
    
    # Import the wrapping key
    import_key_output=$(cloudhsm-cli key import pem --path $WRAPPING_PUBLIC_KEY_PEM --label $WRAP_LABEL --key-type-class rsa-public --attributes wrap=true)
    WRAP_KEY_REF=$(echo "$import_key_output" | jq -r '.data.key["key-reference"]')

    echo "Imported wrapping key to CloudHSM with label = $WRAP_LABEL, key-reference = $WRAP_KEY_REF"

    # Step 4: Wrap the private key inside CloudHSM
    WRAPPED_KEY_FILE="${KEY_REF}_EncryptedKeyMaterial.bin"

    cloudhsm-cli key wrap rsa-oaep \
        --payload-filter "key-reference=$KEY_REF" \
        --wrapping-filter "key-reference=$WRAP_KEY_REF" \
        --hash-function sha256 --mgf mgf1-sha256 \
        --path $WRAPPED_KEY_FILE
    
    echo "Wrapped key saved to: $WRAPPED_KEY_FILE"
    
    # Step 5: Import to KMS
    aws kms import-key-material \
        --key-id $KMS_KEY_ID \
        --encrypted-key-material fileb://$WRAPPED_KEY_FILE \
        --import-token fileb://$IMPORT_TOKEN_BIN \
        --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE

    echo "Successfully imported key $KEY_LABEL to KMS key $KMS_KEY_ID"

    # Step 6: Test Keys in KMS using Public Key in CloudHSM

    # Find the corresponding public key key-reference
    PUBLIC_KEY_REF=$(cat public_keys.json | jq -r --arg EC_POINT "$KEY_EC_POINT" '.data.matched_keys[] | select(.attributes."ec-point" == $EC_POINT) | ."key-reference"')
    # Generate public key PEM file
    PUBLIC_KEY_PEM_FILE="${KEY_REF}_public_key.pem"
    cloudhsm-cli key generate-file --encoding pem --path $PUBLIC_KEY_PEM_FILE --filter "key-reference=$PUBLIC_KEY_REF"
    echo "Generated public key $PUBLIC_KEY_PEM_FILE"

    ### Sign Test Message
    # Create a simple message and encode it in base64 in a text file
    echo -n 'Testing My Imported Key!' | openssl base64 -out test_msg_base64.txt
    # Perform the signing operation by using AWS KMS. Save the signature in file signature.sig
    aws kms sign --key-id $KMS_KEY_ID --message fileb://test_msg_base64.txt --message-type RAW --signing-algorithm ECDSA_SHA_256 | jq -r '.Signature' > test_msg_signature.sig
    # Decode signature from base64 to binary
    openssl enc -d -base64 -in test_msg_signature.sig -out test_msg_signature.bin

    # Verify the signature by using the public key that you exported from CloudHSM
    result=$(openssl dgst -sha256 -verify $PUBLIC_KEY_PEM_FILE -signature test_msg_signature.bin test_msg_base64.txt)

    # Step 7: Save results to CSV file
    if [ "$result" != "Verified OK" ]; then
        echo "FAILED to process CloudHSM key $KEY_REF, $KEY_LABEL"
        echo $KEY_REF,$KEY_LABEL >> result_keys_failed.txt
    else
        echo "SUCCEED to process CloudHSM key $KEY_REF, $KEY_LABEL"
        echo $KEY_REF,$KEY_LABEL,$KMS_KEY_ID >> result_keys_successful.txt
    fi
done

# trap 'rm -f *.b64 *.bin *.pem' EXIT

echo "All keys are processed"
