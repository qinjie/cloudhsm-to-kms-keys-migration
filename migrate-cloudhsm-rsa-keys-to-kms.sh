#!/bin/bash
set -eo pipefail

export PATH=$PATH:/opt/cloudhsm/bin

# CloudHSM config
PRIVATE_KEYS_FILE="private_keys.json"
PUBLIC_KEYS_FILE="public_keys.json"

# Create staging directory for intermediate files
STAGING_DIR="staging"
mkdir -p $STAGING_DIR

TIMESTAMP="$(date '+%Y%m%d_%H%M')"
RESULT_FILE_KEYS_FAILED="result_rsa_keys_failed_$TIMESTAMP.txt"
RESULT_FILE_KEYS_SUCCESSFUL="result_rsa_keys_successful_$TIMESTAMP.txt"
# Create log file with timestamp
LOG_FILE="log_$TIMESTAMP.log"

# Setup result files
echo "CloudHSM_KEY_REF,CLOUDHSM_KEY_LABEL,REASON" > $RESULT_FILE_KEYS_FAILED
echo "CloudHSM_KEY_REF,CLOUDHSM_KEY_LABEL,KMS_KEY_ID" > $RESULT_FILE_KEYS_SUCCESSFUL

# Process each RSA private key only
jq -c '.data.matched_keys[] | select(.attributes["key-type"] == "rsa")' $PRIVATE_KEYS_FILE | while read -r KEY; do
    # Extract key details    
    # KEY_REF: Private key key-reference value
    KEY_REF=$(echo $KEY | jq -r '."key-reference"')
    # KEY_LABEL: Private key attributes.label value
    KEY_LABEL=$(echo $KEY | jq -r '.attributes.label')
    # MODULUS: Private key attribute.modulus value, which will be used to find respective public key key-reference
    KEY_MODULUS=$(echo $KEY | jq -r '.attributes.modulus')
    # MODULUS_SIZE: Private key attribute modulus size in bits
    KEY_MODULUS_SIZE=$(echo $KEY | jq -r '.attributes."modulus-size-bits"')

    # Sample values for TESTING
    # KEY_REF=0x0000000000040da2
    # KEY_LABEL=mvgx-rsa-priv-20
    # KEY_MODULUS=0x00c2b5a...

    echo "CloudHSM Key: $KEY_LABEL, $KEY_REF ---------"
    echo "----------------------------------------------" >> $LOG_FILE
    echo "CloudHSM Key: $KEY_LABEL, $KEY_REF, RSA-$KEY_MODULUS_SIZE" >> $LOG_FILE

    # Step 0: Skip if corresponding public key exists
    PUBLIC_KEY_REF=$(cat $PUBLIC_KEYS_FILE | jq -r --arg MODULUS "$KEY_MODULUS" '.data.matched_keys[] | select(.attributes.modulus == $MODULUS) | ."key-reference"')
    
    if [ "$PUBLIC_KEY_REF" = "null" ] || [ -z "$PUBLIC_KEY_REF" ]; then
        echo "  No corresponding public key found"
        echo "No corresponding public key found in $PUBLIC_KEYS_FILE, skipping key $KEY_REF" >> $LOG_FILE
        echo $KEY_REF,$KEY_LABEL,"No corresponding public key found" >> $RESULT_FILE_KEYS_FAILED
        continue
    fi

    # Step 1: Create KMS key for RSA
    # Determine key spec based on modulus size
    if [ "$KEY_MODULUS_SIZE" = "2048" ]; then
        KEY_SPEC="RSA_2048"
    elif [ "$KEY_MODULUS_SIZE" = "3072" ]; then
        KEY_SPEC="RSA_3072"
    elif [ "$KEY_MODULUS_SIZE" = "4096" ]; then
        KEY_SPEC="RSA_4096"
    else
        echo "  Unsupported RSA key size: $KEY_MODULUS_SIZE"
        echo "Unsupported RSA key size: $KEY_MODULUS_SIZE for key $KEY_REF" >> $LOG_FILE
        echo $KEY_REF,$KEY_LABEL,"Unsupported RSA key size: $KEY_MODULUS_SIZE" >> $RESULT_FILE_KEYS_FAILED
        continue
    fi
    
    echo "Using key spec $KEY_SPEC for RSA-$KEY_MODULUS_SIZE" >> $LOG_FILE
    KMS_KEY_ID=$(aws kms create-key --origin EXTERNAL --key-spec $KEY_SPEC --key-usage SIGN_VERIFY \
        --description "Imported from CloudHSM: $KEY_LABEL" \
        --query 'KeyMetadata.KeyId' --output text 2>> $LOG_FILE)
    echo "Created KMS key: $KMS_KEY_ID" >> $LOG_FILE
    echo "  KMS Key: $KMS_KEY_ID"

    # Step 2: Get wrapping parameters and save to named files
    WRAPPING_PUBLIC_KEY_B64="$STAGING_DIR/${KEY_REF}_WrappingPublicKey.b64"
    WRAPPING_PUBLIC_KEY_BIN="$STAGING_DIR/${KEY_REF}_WrappingPublicKey.bin"
    WRAPPING_PUBLIC_KEY_PEM="$STAGING_DIR/${KEY_REF}_WrappingPublicKey.pem"
    IMPORT_TOKEN_B64="$STAGING_DIR/${KEY_REF}_ImportToken.b64"
    IMPORT_TOKEN_BIN="$STAGING_DIR/${KEY_REF}_ImportToken.bin"
    
    # Save wrapping key parameters to files
    #  Wrapping is always RSA-based regardless of the target key type being imported
    aws kms get-parameters-for-import \
        --key-id "$KMS_KEY_ID" \
        --wrapping-algorithm RSA_AES_KEY_WRAP_SHA_256 \
        --wrapping-key-spec RSA_2048 \
        --query "[ImportToken, PublicKey]" \
        --output text 2>> $LOG_FILE \
        | awk '{print $1 > "'$IMPORT_TOKEN_B64'"; print $2 > "'$WRAPPING_PUBLIC_KEY_B64'"}'

    echo "Saved wrapping parameters to $WRAPPING_PUBLIC_KEY_B64 and $IMPORT_TOKEN_B64" >> $LOG_FILE

    # decode the token from base64 to binary format before it can be used
    openssl enc -d -base64 -A -in $IMPORT_TOKEN_B64 -out $IMPORT_TOKEN_BIN 2>> $LOG_FILE

    # Decode the base64 encoding to binary DER format
    openssl enc -d -base64 -A -in $WRAPPING_PUBLIC_KEY_B64 -out $WRAPPING_PUBLIC_KEY_BIN 2>> $LOG_FILE
    
    # Convert the wrapping public key from DER to PEM format
    openssl rsa -pubin -in $WRAPPING_PUBLIC_KEY_BIN -inform DER -outform PEM -out $WRAPPING_PUBLIC_KEY_PEM 2>> $LOG_FILE
    
    echo "Converted wrapping key to PEM format: $WRAPPING_PUBLIC_KEY_PEM" >> $LOG_FILE

    # Step 3: Import wrapping key to CloudHSM
    WRAP_LABEL="kms_wrapping_key_for_${KEY_REF}"
    
    # Import the wrapping key
    import_key_output=$(cloudhsm-cli key import pem --path $WRAPPING_PUBLIC_KEY_PEM --label $WRAP_LABEL --key-type-class rsa-public --attributes wrap=true 2>> $LOG_FILE)
    WRAP_KEY_REF=$(echo "$import_key_output" | jq -r '.data.key["key-reference"]')
    echo "$import_key_output" >> $LOG_FILE

    echo "Imported wrapping key to CloudHSM with label = $WRAP_LABEL, key-reference = $WRAP_KEY_REF" >> $LOG_FILE

    # Step 4: Wrap the private key inside CloudHSM
    WRAPPED_KEY_FILE="$STAGING_DIR/${KEY_REF}_EncryptedKeyMaterial.bin"

    cloudhsm-cli key wrap rsa-aes \
        --payload-filter "key-reference=$KEY_REF" \
        --wrapping-filter "key-reference=$WRAP_KEY_REF" \
        --hash-function sha256 --mgf mgf1-sha256 \
        --path $WRAPPED_KEY_FILE >> $LOG_FILE 2>&1
    
    echo "Wrapped key saved to: $WRAPPED_KEY_FILE" >> $LOG_FILE
    
    # Step 5: Import to KMS
    aws kms import-key-material \
        --key-id $KMS_KEY_ID \
        --encrypted-key-material fileb://$WRAPPED_KEY_FILE \
        --import-token fileb://$IMPORT_TOKEN_BIN \
        --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE >> $LOG_FILE 2>&1

    echo "Successfully imported key $KEY_LABEL to KMS key $KMS_KEY_ID" >> $LOG_FILE

    # Step 6: Test Keys in KMS using Public Key in CloudHSM

    ### Sign Test Message with CloudHSM ###
    # Create a simple message (raw text, not base64)
    echo -n 'Hello World' > message.txt
    # cat message.txt | openssl base64 -out message_base64.txt

    # Sign using CloudHSM private key
    echo "Signing using CloudHSM private key..."
    # signature.sig contains base64-encoded signature; signature.bin contains binary signature
    cloudhsm-cli crypto sign rsa-pkcs --key-filter "key-reference=$KEY_REF" --hash-function sha256 --data-path message.txt --data-type raw | jq -r '.data.signature' > signature.sig
    # Decode the base64 signature to binary format
    openssl enc -d -base64 -in signature.sig -out signature.bin

    # # Option 1: Verify using CloudHSM public key
    # cloudhsm-cli crypto verify rsa-pkcs --key-filter "key-reference=$PUBLIC_KEY_REF" --hash-function sha256 --data-path message.txt --signature-path signature.bin --data-type raw > verification.txt 2>&1
    # # Check verification result
    # result=$( [ "$(jq -r '.error_code // 1' verification.txt 2>/dev/null || echo 1)" -eq 0 ] && echo "success" || echo "failure" )
    # echo "Verification using CloudHSM public key: $result"

    # # Option 2: Verify using OpenSSL and PEM file from CloudHSM public key
    # # Export public key to PEM
    # cloudhsm-cli key generate-file --encoding pem --path public_key_cloudhsm.pem --filter "key-reference=$PUBLIC_KEY_REF" > /dev/null 2>&1
    # # Verify using PEM file and binary signature (RSA signatures don't need DER conversion)
    # openssl dgst -sha256 -verify public_key_cloudhsm.pem -signature signature.bin message.txt > verification.txt 2>&1
    # result=$(grep -q "Verified OK" verification.txt && echo "success" || echo "failure")
    # echo "Verification using PEM of CloudHSM public key: $result"

    # Option 3: Verify using KMS Public Key
    aws kms verify --key-id $KMS_KEY_ID --message fileb://message.txt --message-type RAW --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 --signature fileb://signature.bin --output json > verification.txt

    result=$(cat verification.txt | jq -r 'if .SignatureValid then "success" else "failure" end')
    echo "Verification using KMS public key: $result"

    # # Option 4: Verify using OpenSSL and PEM file from KMS public key
    # aws kms get-public-key --key-id $KMS_KEY_ID --query 'PublicKey' --output text | base64 --decode > public_key.der 2>/dev/null
    # # Convert public key from KMS in DER (binary) format to PEM (Base64-encoded), use OpenSSL for RSA
    # openssl rsa -pubin -inform DER -in public_key.der -outform PEM -out public_key.pem > /dev/null 2>&1
    # # Verify using PEM file and binary signature (RSA signatures are already in correct format)
    # openssl dgst -sha256 -verify public_key.pem -signature signature.bin message.txt > verification.txt 2>&1
    # result=$(grep -q "Verified OK" verification.txt && echo "success" || echo "failure")
    # echo "Verification using PEM of KMS public key: $result"


    # Step 7: Save results to CSV file
    if [ "$result" != "success" ]; then
        echo "FAILED to process CloudHSM key $KEY_REF, $KEY_LABEL" | tee -a $LOG_FILE
        echo $KEY_REF,$KEY_LABEL,"Verification failed: $result" >> $RESULT_FILE_KEYS_FAILED
    else
        echo "SUCCEED to process CloudHSM key $KEY_REF, $KEY_LABEL" | tee -a $LOG_FILE
        echo $KEY_REF,$KEY_LABEL,$KMS_KEY_ID >> $RESULT_FILE_KEYS_SUCCESSFUL
    fi
done

echo "------ All keys are processed --------" | tee -a $LOG_FILE
