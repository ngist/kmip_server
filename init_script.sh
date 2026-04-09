#!/bin/bash
# This setups up an EC2 instance to act as a KMIP server for synology NAS and/or other things. 
# It uses CosmianKMS to act as the KMIP server, and provides a DDNS script to update IP address 
# if the instance is rebooted without needing a static IP.
# You'll need to add an IAM role with permissions to update the DNS entries. 
# You'll need to download the certs for the NAS's ussing `sftp kmip.example.com:cert_package.zip ./OneDrive/Desktop`
#References
# https://docs.cosmian.com/key_management_system/integrations/storage/synology_dsm/
# Generated based on https://www.reddit.com/r/synology/comments/1fe200i/how_to_setup_volume_encryption_with_remote_kmip/

#Change these to match your needs
ROOT_DOMAIN=example.com
LUKS_PASSWORD=`openssl rand -base64 20`
ZONE_ID=Z1234EXAMPLE
KEY_LENGTH=4096

dnf install -y docker
systemctl start docker

mkdir /opt/luks
# Setup LUKS image to hold cosmian data
cd /opt/luks
dd if=/dev/zero of=vault.img bs=1M count=20
echo $LUKS_PASSWORD | cryptsetup luksFormat vault.img -d -

mkdir /etc/cosmian
echo $LUKS_PASSWORD | cryptsetup open --type luks vault.img myvault
ls /dev/mapper/myvault
mkfs.ext4 -L myvault /dev/mapper/myvault
mount /dev/mapper/myvault /etc/cosmian/
df

mkdir /etc/cosmian/data

KMS_PATH=/etc/cosmian/kms
mkdir $KMS_PATH 

P12_PASSWORD=`openssl rand -base64 20`
# Generate config
cat << EOF > /etc/cosmian/kms/kms.toml
[tls]
tls_p12_file    = "/etc/cosmian/kms/server.p12"
tls_p12_password = "$P12_PASSWORD"
clients_ca_cert_file = "/etc/cosmian/kms/clients-ca.crt"

[socket_server]
socket_server_start    = true
socket_server_port     = 5696        # standard KMIP port
socket_server_hostname = "0.0.0.0"

[kmip]
policy_id = "DEFAULT"
EOF

# Generate a CA certificate
cd $KMS_PATH
openssl genrsa -out clients-ca.key $KEY_LENGTH
openssl req -new -x509 -days 3650 -key clients-ca.key \
  -subj "/CN=KMS Clients CA" -out clients-ca.crt

# Renew Cert scripts
echo "#!/bin/bash" > /etc/cosmian/renew_certs.sh
echo "ROOT_DOMAIN=$ROOT_DOMAIN" > /etc/cosmian/renew_certs.sh
echo "P12_PASSWORD=$P12_PASSWORD" >> /etc/cosmian/renew_certs.sh
echo "KMS_PATH=$KMS_PATH" >> /etc/cosmian/renew_certs.sh
echo "KEY_LENGTH=$KEY_LENGTH" >> /etc/cosmian/renew_certs.sh
cat << 'EOF' >> /etc/cosmian/renew_certs.sh
cd /etc/cosmian/
clients="nas nas2 kmip"
for i in $clients; do 
  openssl genrsa -out $i.key $KEY_LENGTH
  openssl req -new -key $i.key \
    -subj "/CN=$i" -out $i.csr \
    -addext "subjectAltName = DNS:$i.$ROOT_DOMAIN" \
    -addext "extendedKeyUsage = serverAuth, clientAuth"
  openssl x509 -req -days 1096 -in $i.csr \
    -CA $KMS_PATH/clients-ca.crt -CAkey $KMS_PATH/clients-ca.key -CAcreateserial \
    -out $i.crt -copy_extensions copy
done
openssl pkcs12 -export -out $KMS_PATH/server.p12 -inkey kmip.key -in kmip.crt --password pass:$P12_PASSWORD
rm kmip.*
cp $KMS_PATH/clients-ca.crt clients-ca.crt
zip cert_package.zip *.crt *.key
rm *.crt *.csr *.key
EOF
chmod +x /home/ec2-user/renew_certs.sh

#Setup DDNS
echo "#!/bin/bash" > /home/ec2-user/ddns.sh
echo "ROOT_DOMAIN=$ROOT_DOMAIN" >> /home/ec2-user/ddns.sh
echo "ZONE_ID=$ZONE_ID" >> /home/ec2-user/ddns.sh
cat << 'EOF' >> /home/ec2-user/ddns.sh
DOMAIN=kmip.$ROOT_DOMAIN
IP4=`curl -4 ipv4.icanhazip.com`
IP6=`curl -6 ipv6.icanhazip.com`
cat <<EOFX >/home/ec2-user/change_set.json
{
  "Comment": "Add record to point to EC2 instance",
  "Changes": [
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN",
        "Type": "A",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "$IP4"
          }
        ]
      }
    },
    {
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "$DOMAIN",
        "Type": "AAAA",
        "TTL": 60,
        "ResourceRecords": [
          {
            "Value": "$IP6"
          }
        ]
      }
    }
  ]
}
EOFX
aws route53 change-resource-record-sets --hosted-zone-id $ZONE_ID --change-batch file:///home/ec2-user/change_set.json
EOF
chmod +x /home/ec2-user/ddns.sh

cat << 'EOF' > /etc/systemd/system/ddns.service
[Unit]
After=network.target

[Service]
ExecStart=/home/ec2-user/ddns.sh
Type=OneShot

[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable ddns.service
systemctl start ddns.service

/home/ec2-user/renew_certs.sh

sudo docker run --name cosmian-kms -d -p 9998:9998 -p 5696:5696 \
  -v /etc/cosmian/kms:/etc/cosmian/kms:ro \
  -v /etc/cosmian/data:/var/lib/cosmian-kms:rw \
  -e COSMIAN_KMS_CONF=/etc/cosmian/kms/kms.toml \
  ghcr.io/cosmian/kms:latest
