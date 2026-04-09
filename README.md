# Overview
Simple repo to setup a kmip server compatible with synology NAS using CosmianKMS for the backend on AWS.
This is specifically intended for use on AWS EC2 and route 53, but it could be used as a starting point for other cloud providers, not much other than the DDNS functionality depends on AWS.

This was inspired by https://github.com/rnurgaliyev/kmip-server-dsm but that project relies on a dead project(PyKMIP) for the backend server. I didn't want to rely on something unmaintained, and out of date. 
Enter CosmianKMS this is enterprise software, but using it for free if used on less than 4 vCPUS or 2 baremetal CPUs is allowed per license(at time of writting), which is more than sufficient for this purpose 
and they built support specifically for Synology. 
See: https://docs.cosmian.com/key_management_system/integrations/storage/synology_dsm/

The init script is intended for use on AWS EC2. It will generate the root CA for signing KMIP certs, as well as certs for the server, and two client NASs. 

If you use route53 for DNS this script will also act as a DDNS that runs at boot so no static IP is required.

> [!WARNING]  
> This involves changing your key vault on your NAS, make sure you've got your volume recovery keys stored somewhere safe. If you do everything right you shouldn't have any problems but if you switch to KMIP then delete the server with your keys and don't have your volume recovery keys somewhere you could lose data.
> You should make sure you understand the implications of mode 1 and 2 resets should you ever need them and how to recover from them before proceeding:
> https://kb.synology.com/en-global/DSM/tutorial/How_to_reset_my_Synology_NAS_7

# Prerequisites
1. This assumes you already have an AWS account, and some basic understanding of how to setup IAM, roles and launch scripts etc.
2. You should setup you EC2 VPC to have dual IP stack for the DDNS to work properly. See:
   https://docs.aws.amazon.com/vpc/latest/userguide/vpc-migrate-ipv6.html
3. Setup IAM assumable role for your EC2 instance to use for DDNS functionality, there's a sample to min scoped policy in the repo.
4. You have a security group setup that allows external access on port 5696 and port 22. 

# How to use
1. Modify the variables at the beginning of the init script to match your needs.
2. Launch a new EC2 instance, I used t4g.nano and base image ami-088cedaa951dcc6a5, and supply the init_script.sh as the user-data/init_script make sure it's setup for dual stack IP or the DDNS won't work. 
3. Once setup has finished download the cert_package.zip `sftp ec2-user@kmip.example.com:/etc/cosmian/cert_package.zip ~/`
4. Unzip the cert package and upload the certs to your NASes by default the script generates certs for two NASes but you can edit the `client=` to add as many as you need.
   - First import the client cert into the synology NAS Control Panel > Security > Certificates > Add
   - For description put in something useful like CosmianClient or KMIP_Client
   - For Private Key: upload nasX.key
   - For Certificate: upload nasX.crt
   - For Intermediate certificate: upload clients-ca.crt
5. In the certificate manager click settings, and select the cert you just added for the KMIP service.
6. Goto the KMIP tab and select "Set as remote key client"
   - Set the hostname kmip.yourdomain.com
   - Port to 5696
   - upload clients-ca.crt for the Certificate Authority
7. Open storage manager click your storage pool and open global settings
   a. Reset your vault and configure it to use KMIP. This will clear the keys from your local key vault.
8. The client certs are only valid for 3 years, and the Root CA is valid for 10. You'll need to periodically refresh the certs on your NAS to do this ssh into the EC2 instance run `./renew_certs.sh` and then redownload the cert package and distribute the certs. There's no built-in script for refreshing the Root CA, but you can copy from the init script every 10 years, assuming your still using this.
9. Make a backup of your /opt/luks/vault.img
10. I'd strongly recommend testing that everything is working, do a reboot of your NAS to make sure the volumes unlock, then shutdown the KMIP server, and reboot again to verify they are locked.
    
> [!IMPORTANT]
> By default a random passphrase is generated for the LUKS image and it is stored in /opt/luks/passphrase you should download and delete this from the server for added security you could change the passphrase.

> [!NOTE]
> After running init the kmip server will be active, if you'd like to only have it online when you need it you can start and stop it manually with the following ssh commands
> `ssh ec2-user@kmip.example.com 'nohup sudo ./start_kmip.sh VAULT_PASS &>/dev/null &'`
> `ssh ec2-user@kmip.example.com 'nohup sudo ./stop_kmip.sh VAULT_PASS &>/dev/null &'`
> or if you only want it up for a few minutes for a reboot cycle `ssh ec2-user@kmip.example.com 'nohup sudo ./ephemeral_kmip.sh VAULT_PASS DURATION_SECONDS &>/dev/null &'`
> If you want to send the commands from you phone see this guide https://www.reddit.com/r/synology/comments/1fe200i/how_to_setup_volume_encryption_with_remote_kmip/

# Troubleshooting:
1. Did you skip step 5 above?
2. Check that DNS entries for your kmip are there and have the right IP.
3. Did you setup a security group to allow access on port 5696 to your EC2 instance.
4. Is the cosmian kms docker container running? Try `sudo docker ps` you should see something if not manually restart using the `start_kmip.sh` script
