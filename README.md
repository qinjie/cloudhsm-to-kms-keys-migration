# CloudHSM to KMS Keys Migration

The AWS blog post ["How to migrate asymmetric keys from CloudHSM to AWS KMS"](https://aws.amazon.com/blogs/security/how-to-migrate-asymmetric-keys-from-cloudhsm-to-aws-kms/) provides detailed, step-by-step guidance on how to securely migrate asymmetric key (such as an RSA or ECC private key) from AWS CloudHSM to AWS Key Management Service (KMS). While it provides a step-by-step method for migrating a single asymmetric key from CloudHSM to AWS KMS, it does't offer a systematic process for bulk migration of many keys.

This project provides a set of scripts to facilitate the bulk migration of asymmetric cryptographic keys (such as RSA and ECC keys) from AWS CloudHSM to AWS Key Management Service (KMS). It provides the list of CloudHMS to KMS key pairs in the `result_keys_succuessful.txt` file. CloudHSM keys, which failed to process, will be saved in `result_keys_failed.txt` file.

Here are the key functionalities:

- Test Key Generation: Script `generate-cloudhsm-test-keys.sh` to create test ECC key pairs in CloudHSM for testing the migration process.

- Key Listing: Scripts `list-cloudhsm-private-keys.sh` and `list-cloudhsm-public-keys.sh` to enumerate all private and public keys stored in CloudHSM, saving detailed key information to JSON files `private_keys.json` and `public_keys.json` for processing.

- Bulk Key Migration: The main script (`migrate-cloudhsm-keys-to-ksm.sh`) that:

  - Reads private key information from JSON files
  - Creates a new KMS key for each CloudHSM key being migrated
  - Obtains wrapping parameters from AWS KMS
  - Imports the KMS wrapping key into CloudHSM
  - Wraps the private key inside CloudHSM using the imported wrapping key
  - Imports the wrapped key material into AWS KMS
  - Validates the migration by performing a sign/verify test operation
  - Tracks successful and failed migrations in result files

- Key Cleanup: A utility script (`delete-cloudhsm-keys-by-regex.sh`) to delete keys from CloudHSM that match a specific pattern, useful for cleaning up after testing.

This script also enhances the commands in original blog post with:

- Use `key-reference` to replace `attributes.label` as key filter. Some commands requires a single key to be filtered. The `key-reference` value uniquely identifies each key, where as `attribute.label` may match multiple keys. This ensure reproduciblity of the test scripts.

- Clarities on the key used in each command. Example, in step 4 of the blog, the key to be exported must be the respective public key of the current private key.


## Pre-requisites

This guide only works on Windows or Linux since CloudHSM-CLI is not available in Mac.

This project assumes that the CloudHSM cluster has been setup and activated. Crypto-user has been created. CloudHSM-CLI is installed.

1. Add CloudHSM bin folder to PATH so that we can use `cloudhsm-cli` instead of `/opt/cloudhsm/bin/cloudhsm-cli`.

```
export PATH=$PATH:/opt/cloudhsm/bin
```

2. Set CloudHSM User in environment variables. Replace username and password accordingly. This is so that you can call `cloudhsm-cli` directly in terminal.

```
export CLOUDHSM_ROLE=crypto-user
export CLOUDHSM_PIN="user2:Mylife123"
```

## Steps

1. Generate list of CloudHSM keys for testing. Update label for public key and private key accordingly.

```
./generate-cloudhsm-test-keys.sh
```

2. List all private keys and public keys in CloudHSM. This will save the key info in `public_keys.json` and `private_keys.json` files. For EC keys, the private key and public key share the same `ec-point` value.

```
./list-cloudhsm-public-keys.sh
./list-cloudhsm-private-keys.sh
```

3. Run the script to migrate keys from CloudHSM to KMS. This script requires the `public_keys.json` and `private_keys.json` files from previous step.

```
./migrate-cloudhsm-keys-to-ksm.sh
```

4. Examine the migration results in output files.

```
cat result_keys_successful.txt
cat result_keys_failed.txt
```

5. Clean up keys in CloudHSM after testing. Ajust the regex vlaue accordingly to delete a subset of keys.

```
./delete-cloudhsm-keys-by-regex.sh
```

## Inside Migration Script

### Step 1: Create a KMS key without key material in AWS KMS

This is a new KMS key which will be migrated from a CloudHSM Key. The key material will be provided by the existing key in CloudHSM.

```
export KMS_KEY_ID=$(aws kms create-key --origin EXTERNAL --key-spec ECC_NIST_P256 --key-usage SIGN_VERIFY --query 'KeyMetadata.KeyId' --output text)

echo $KMS_KEY_ID
```

### Step 2: Download the wrapping public key and import token from AWS KMS

We can download a wrapping key for above KMS key. The wrapping key will be imported into CloudHSM to encrypt the target key in CloudHMS before it is exported.

```
aws kms get-parameters-for-import \
  --key-id "$KMS_KEY_ID" \
  --wrapping-algorithm RSAES_OAEP_SHA_256 \
  --wrapping-key-spec RSA_4096 \
  --query "[ImportToken, PublicKey]" \
  --output text \
  | awk '{print $1 > "ImportToken.b64"; print $2 > "WrappingPublicKey.b64"}'

```

Decode the base64 encoding

```
openssl enc -d -base64 -A -in WrappingPublicKey.b64 -out WrappingPublicKey.bin

ls -la WrappingPublicKey*
```

Convert the wrapping public key from DER to PEM format

```
openssl rsa -pubin -in WrappingPublicKey.bin -inform DER -outform PEM -out WrappingPublicKey.pem

ls -la WrappingPublicKey*
```

### Step 3: Import the wrapping key provided by AWS KMS into CloudHSM

You may change the label value. You will need to use the same label value to refer to the wrapping key.

```
cloudhsm-cli key import pem --path ./WrappingPublicKey.pem --label kms-wrapping-key --key-type-class rsa-public --attributes wrap=true
```

### Step 4: Wrap the private key inside CloudHSM with the imported wrapping public key from AWS KMS

Save the wrapped key.

```
cloudhsm-cli key wrap rsa-oaep \
    --payload-filter "key-reference=$KEY_REF" \
    --wrapping-filter "key-reference=$WRAP_KEY_REF" \
    --hash-function sha256 --mgf mgf1-sha256 \
    --path $WRAPPED_KEY_FILE
```

### Step 5: Import the wrapped key material to AWS KMS

Once the key is wrapped, import it to AWS KMS using the import token:

```
aws kms import-key-material \
    --key-id $KMS_KEY_ID \
    --encrypted-key-material fileb://$WRAPPED_KEY_FILE \
    --import-token fileb://$IMPORT_TOKEN_BIN \
    --expiration-model KEY_MATERIAL_DOES_NOT_EXPIRE
```

### Step 6: Test the migrated key by signing and verifying

To ensure the migration was successful, perform a sign/verify test:

1. First, find the corresponding public key in CloudHSM:

```
PUBLIC_KEY_REF=$(cat public_keys.json | jq -r --arg EC_POINT "$KEY_EC_POINT" '.data.matched_keys[] | select(.attributes."ec-point" == $EC_POINT) | ."key-reference"')
```

2. Export the public key to PEM format:

```
cloudhsm-cli key generate-file --encoding pem --path $PUBLIC_KEY_PEM_FILE --filter "key-reference=$PUBLIC_KEY_REF"
```

3. Create a test message and sign it with the KMS key:

```
echo -n 'Testing My Imported Key!' | openssl base64 -out test_msg_base64.txt
aws kms sign --key-id $KMS_KEY_ID --message fileb://test_msg_base64.txt --message-type RAW --signing-algorithm ECDSA_SHA_256 | jq -r '.Signature' > test_msg_signature.sig
openssl enc -d -base64 -in test_msg_signature.sig -out test_msg_signature.bin
```

4. Verify the signature using the public key from CloudHSM:

```
openssl dgst -sha256 -verify $PUBLIC_KEY_PEM_FILE -signature test_msg_signature.bin test_msg_base64.txt
```

### Step 7: Record migration results

The script tracks the success or failure of each key migration:

- For successful migrations, the CloudHSM key reference, label, and corresponding KMS key ID are recorded in `result_keys_successful.txt`
- For failed migrations, the CloudHSM key reference and label are recorded in `result_keys_failed.txt`

This allows for easy tracking of which keys were successfully migrated and which ones may need attention.
