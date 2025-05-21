# Setup CloudHSM

## Setup CloudHSM and KMS

This is to setup CloudHSM and KMS so that we can test the python script.

### Initialize CloudHSM with Sample Keys

This step creates a CloudHSM cluster with 1 HSM instance in Singapore region.

### Successful Steps We Performed

#### Step 1: Create a CloudHSM Cluster

```bash

aws cloudhsmv2 create-cluster \

--hsm-type hsm2m.medium \

--mode FIPS \

--subnet-ids subnet-09bb7fdaf05e437bf \

--region ap-southeast-1

```

Result:

```
{

"Cluster": {

"BackupPolicy": "DEFAULT",

"BackupRetentionPolicy": {

"Type": "DAYS",

"Value": "90"

},

"ClusterId": "cluster-fhtbm47tsjo",

"CreateTimestamp": "2025-05-16T13:56:20.978000+08:00",

"Hsms": [],

"HsmType": "hsm2m.medium",

"State": "CREATE_IN_PROGRESS",

"SubnetMapping": {

"ap-southeast-1a": "subnet-09bb7fdaf05e437bf"

},

"VpcId": "vpc-0544788d30aeff7a0",

"NetworkType": "IPV4",

"Certificates": {},

"Mode": "FIPS"

}

}

```

#### Step 2: Create an HSM Instance in the Cluster

```bash

aws cloudhsmv2 create-hsm \

--cluster-id cluster-fhtbm47tsjo \

--availability-zone ap-southeast-1a \

--region ap-southeast-1

```

Result:

```

{

"Hsm": {

"AvailabilityZone": "ap-southeast-1a",

"ClusterId": "cluster-fhtbm47tsjo",

"SubnetId": "subnet-09bb7fdaf05e437bf",

"HsmId": "hsm-7qsltqrczv5",

"HsmType": "hsm2m.medium",

"State": "CREATE_IN_PROGRESS"

}

}

```

#### Step 3: Wait for the Cluster and HSM to be Available

```bash

aws cloudhsmv2 describe-clusters --filters clusterIds=cluster-fhtbm47tsjo --query "Clusters[0].State" --region ap-southeast-1

```

Result:

```

"UNINITIALIZED"

```

#### Step 4: Create Certificate Authority for Cluster Initialization

```bash

# 1. Create a self-signed certificate authority (CA)

openssl genrsa -out customerCA.key 2048

openssl req -new -x509 -days 3652 -key customerCA.key -out CustomerCA.crt -subj "/CN=CloudHSM-CA/O=YourOrganization/C=SG"

```

#### Step 5: Get the Cluster's CSR and Sign It

```bash

# 2. Get the CSR from the cluster

aws cloudhsmv2 describe-clusters --filters clusterIds=cluster-fhtbm47tsjo --query "Clusters[0].Certificates.ClusterCsr" --output text --region ap-southeast-1 > ClusterCsr.csr



# 3. Sign the CSR with your CA

openssl x509 -req -days 3652 -in ClusterCsr.csr -CA CustomerCA.crt -CAkey customerCA.key -CAcreateserial -out CustomerHsmCertificate.crt

```

Result:

```

-rw-r--r-- 1 qinjie staff 1281 16 May 14:13 CustomerHsmCertificate.crt

Certificate request self-signature ok

subject=C=US + ST=CA + OU=LS2 + L=SanJose + O=Marvell, CN=HSM:RCN2345B07362:PARTN:25, for FIPS mode

```

#### Step 6: Initialize the Cluster with the Signed Certificate

```bash

aws cloudhsmv2 initialize-cluster \

--cluster-id cluster-fhtbm47tsjo \

--region ap-southeast-1 \

--signed-cert file://CustomerHsmCertificate.crt \

--trust-anchor file://CustomerCA.crt

```

Result:

```

{

"State": "INITIALIZE_IN_PROGRESS",

"StateMessage": "Cluster is initializing. State will change to INITIALIZED upon completion."

}

```

#### Step 7: Wait for Initialization to Complete

```bash

aws cloudhsmv2 describe-clusters --filters clusterIds=cluster-fhtbm47tsjo --query "Clusters[0].[State,Hsms[0].State,Hsms[0].HsmId]" --region ap-southeast-1

```

Result:

```

[

"INITIALIZED",

"ACTIVE",

"hsm-7qsltqrczv5"

]

```

#### Step 8: Get HSM IP Address for Client Configuration

```bash

aws cloudhsmv2 describe-clusters --filters clusterIds=cluster-fhtbm47tsjo --query "Clusters[0].Hsms[0].EniIp" --output text --region ap-southeast-1

```

Result:

```

10.0.15.200

```

### Activation of CloudHSM Cluster using CloudHSM-CLI

https://docs.aws.amazon.com/cloudhsm/latest/userguide/activate-cluster.html

```
export PATH=$PATH:/opt/cloudhsm/bin
```

### Clean Up Resources After Testing

```bash

# Delete KMS keys

aws kms schedule-key-deletion --key-id KEY_ID --pending-window-in-days 7 --region ap-southeast-1



# Delete the CloudHSM cluster (must delete HSM instances first)

aws cloudhsmv2 delete-hsm \

--cluster-id cluster-fhtbm47tsjo \

--hsm-id hsm-7qsltqrczv5 \

--region ap-southeast-1



aws cloudhsmv2 delete-cluster \

--cluster-id cluster-fhtbm47tsjo \

--region ap-southeast-1

```

```

/opt/cloudhsm/bin/cloudhsm-cli interactive

```

Login an user with `crypto-user` role.

```

aws-cloudhsm > login --username user1 --role crypto-user

```

## Clean Up Keys in CloudHSM

### Use cryto-user in Terminal

In terminal, set CloudHSM User in environment variables. Replace username and password accordingly.

```
export PATH=$PATH:/opt/cloudhsm/bin

export CLOUDHSM_ROLE=crypto-user
export CLOUDHSM_PIN="user2:Mylife123"
```

Test the credential. Make sure it runs successfully.

```

cloudhsm-cli user list

```

List all keys in CloudHSM

```

cloudhsm-cli key list

```

### Create Some Sample Keys

Keys with `secp256k1` must use wrapping key `ECC_SECG_P256K1`.
Keys with `prime256v1` must use wrapping key `ECC_NIST_P256`.
Keys with `nist-p256` curve will have problem in wrapping because it is not supported in CloudHSM.

```
for i in {1..20}; do
	cloudhsm-cli key generate-asymmetric-pair ec \
		--public-label "mvgx-pub-$i" \
		--private-label "mvgx-priv-$i" \
		 --curve secp256k1
done
```

### Clean up Keys in CloudHSM

Delete keys which matching to the label_pattern.

```
label_pattern="^mvgx-priv-6"

key_labels=$(cloudhsm-cli key list --max-items 100 --verbose | jq -r '.data.matched_keys[].attributes.label' | grep -E "$label_pattern")

echo $key_labels

while read -r label; do
	echo "Keys matching label: $label"

	matching_keys=$(cloudhsm-cli key list --filter attr.label="$label" --verbose)
	echo $matching_keys

	while read -r ref_key; do
		cloudhsm-cli key delete --filter key-reference="$ref_key"
	done <<< "$matching_keys"

done <<< "$key_labels"
```

## Setup CloudHSM CLI

Check the Ubuntu version

```
lsb_release -a
```

Download CloudHSM SDK 5 for Ubuntu. Get the link from https://docs.aws.amazon.com/cloudhsm/latest/userguide/latest-releases.html

```
wget https://s3.amazonaws.com/cloudhsmv2-software/CloudHsmClient/Noble/cloudhsm-cli_5.16.0-1_u24.04_amd64.deb
```

Install CloudHSM CLI and add it to path

```
sudo apt install ./cloudhsm-cli_5.16.0-1_u24.04_amd64.deb

export PATH=$PATH:/opt/cloudhsm/bin
/opt/cloudhsm/bin/cloudhsm-cli --version
```

### Activate CloudHSM Cluster

Get IP address of CloudHSM Cluster

```
aws cloudhsmv2 describe-clusters \
  --query "Clusters[*].Hsms[*].{EniIp: EniIp, EniIpV6: EniIpV6}" \
  --output table
```

Configure CloudHSM CLI.

```
sudo /opt/cloudhsm/bin/configure-cli -a <CloudHSM_IP>
```

Note:

- You must copy the `customerCA.crt` to `/opt/cloudhsm/etc/customerCA.crt` on your client EC2 instance.

```
ls /opt/cloudhsm/etc/customerCA.crt
```

- Your computer or EC2 instance must be able to connect to CloudHSM Instance at port 2223.

```
nc -vz <CloudHSM_IP> 2223
```

Run CloudHSM CLI in interactive mode.

- The `aws-cloudhsm >` prompt should appear. If not, check the connection between your computer or EC2 instance with the CloudHSM Instance.

```
/opt/cloudhsm/bin/cloudhsm-cli interactive

aws-cloudhsm > user list
```

Activate the cluster, which will require you to set password for admin.

```
aws-cloudhsm > cluster activate
```

![](CloudHSM-to-KMS-Keys-Migration.assets/file-20250519101413643.jpg)

The state of the CloudHSM cluster should changed from `Initialized` to `Active`.

### Create an user with Role cryto-user

Login as admin user.

```
login --username admin --role admin
```

Create an user with `cryto-user` role.

```
user create --username user1 --role crypto-user
```

### Use cryto-user in Terminal

In terminal, set CloudHSM User in environment variables. Replace username and password accordingly.

```
export PATH=$PATH:/opt/cloudhsm/bin

export CLOUDHSM_ROLE=crypto-user
export CLOUDHSM_PIN="user2:Mylife123"
```

Test the credential. Make sure it runs successfully.

```
cloudhsm-cli user list
```

### Create Sample Keys

Create 20 sample keys for testing.

```
for i in {1..20}; do
  cloudhsm-cli key generate-asymmetric-pair rsa \
    --public-label "rsa-pub-$i" \
    --private-label "rsa-priv-$i" \
    --modulus-size-bits 2048 \
    --public-exponent 65537;
done
```

```
for i in {1..20}; do
  cloudhsm-cli key generate-asymmetric-pair ec \
    --curve secp256k1 \
    --public-label "ec-pub-$i" \
    --private-label "ec-priv-$i";
done
```

### Clean up Keys in CloudHSM

```
pattern="rsa-*"

key_labels=$(cloudhsm-cli key list --verbose | jq -r '.data.matched_keys[].attributes.label' | grep -E "$pattern")

echo $key_labels



while read -r label; do

cloudhsm-cli key delete --filter attr.label="$label"

done <<< "$key_labels"
```
