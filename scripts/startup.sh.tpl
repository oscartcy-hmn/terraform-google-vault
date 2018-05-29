#!/bin/bash -xe

apt-get update
apt-get install -y unzip jq netcat nginx

# Download and install Vault
cd /tmp && \
  gsutil cp gs://${storage_bucket}-image/${vault_image} . && \
  unzip ${vault_image} && \
  mv vault /usr/local/bin/vault && \
  rm ${vault_image}

# Install Stackdriver for logging
curl -sSL https://dl.google.com/cloudagents/install-logging-agent.sh | bash

# Get External IP
EXTERNAL_IP=$(curl -H "Metadata-Flavor: Google" http://metadata/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip)

# Vault config
mkdir -p /etc/vault
cat - > /etc/vault/config.hcl <<EOF
api_addr = "https://$${EXTERNAL_IP}:8200"
EOF

cat - >> /etc/vault/config.hcl <<'EOF'
${config}
EOF
chmod 0600 /etc/vault/config.hcl

# Service account key JSON credentials encrypted in GCS.
if [[ ! -f /etc/vault/gcp_credentials.json ]]; then
  gcloud kms decrypt \
    --location global \
    --keyring=${kms_keyring_name} \
    --key=${kms_key_name} \
    --plaintext-file /etc/vault/gcp_credentials.json \
    --ciphertext-file=<(gsutil cat gs://${assets_bucket}/${vault_sa_key} | base64 -d)
  chmod 0600 /etc/vault/gcp_credentials.json
fi

# Service environment
cat - > /etc/vault/vault.env <<EOF
VAULT_ARGS=${vault_args}
EOF
chmod 0600 /etc/vault/vault.env

# TLS key and certs
for tls_file in ${vault_ca_cert} ${vault_tls_key} ${vault_tls_cert}; do 
  gcloud kms decrypt \
    --location global \
    --keyring=${kms_keyring_name} \
    --key=${kms_key_name} \
    --plaintext-file /etc/vault/$${tls_file//.encrypted.base64/} \
    --ciphertext-file=<(gsutil cat gs://${assets_bucket}/$${tls_file} | base64 -d)
  chmod 0600 /etc/vault/$${tls_file//.encrypted.base64/}
done

# Systemd service
cat - > /etc/systemd/system/vault.service <<'EOF'
[Service]
EnvironmentFile=/etc/vault/vault.env
ExecStart=
ExecStart=/usr/local/bin/vault server -config=/etc/vault/config.hcl $${VAULT_ARGS}
EOF
chmod 0600 /etc/systemd/system/vault.service

systemctl daemon-reload
systemctl enable vault
systemctl start vault

# Setup vault env
export VAULT_ADDR=https://127.0.0.1:8200
export VAULT_CACERT=/etc/vault/vault-server.ca.crt.pem
export VAULT_CLIENT_CERT=/etc/vault/vault-server.crt.pem
export VAULT_CLIENT_KEY=/etc/vault/vault-server.key.pem

# Add health-check proxy, GCE doesn't support https health checks.
cat - > /etc/nginx/sites-available/default <<EOF
server {
    listen 80;
    location / {
        proxy_pass $${VAULT_ADDR}/v1/sys/health?standbyok=true&sealedcode=200;
    }
}
EOF
systemctl enable nginx
systemctl restart nginx

# Wait 30s for Vault to start
(while [[ $count -lt 15 && "$(vault status 2>&1)" =~ "connection refused" ]]; do ((count=count+1)) ; echo "$(date) $count: Waiting for Vault to start..." ; sleep 2; done && [[ $count -lt 15 ]])
[[ $? -ne 0 ]] && echo "ERROR: Error waiting for Vault to start" && exit 1

# Initialize Vault, save encrypted unseal and root keys to Cloud Storage bucket.
if [[ $(vault status) =~ "Sealed: true" ]]; then
  echo "Vault already initialized"
else
  vault init > /tmp/vault_unseal_keys.txt

  gcloud kms encrypt \
    --location=global  \
    --keyring=${kms_keyring_name} \
    --key=${kms_key_name} \
    --plaintext-file=/tmp/vault_unseal_keys.txt \
    --ciphertext-file=/tmp/vault_unseal_keys.txt.encrypted

  gsutil cp /tmp/vault_unseal_keys.txt.encrypted gs://${assets_bucket}

  ROOT_TOKEN=$(cat /tmp/vault_unseal_keys.txt | grep "Initial Root Token: \K(.*)$" -Po)

  rm -f /tmp/vault_unseal_keys.txt*

  # vault configuration
  (while [[ $count -lt 15 && "($vault login $${ROOT_TOKEN} 2>&1)" =~ "local node not active but active cluster node not found" ]]; do ((count=count+1)) ; echo "$(date) $count: Waiting for Vault to login..." ; sleep 2; done && [[ $count -lt 15 ]])
  vault write sys/license text=${vault_license_key}
  vault audit-enable syslog

fi