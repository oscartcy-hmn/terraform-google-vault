listener "tcp" {
  address = "0.0.0.0:8200"
  tls_cert_file = "/etc/vault/vault-server.crt.pem"
  tls_key_file = "/etc/vault/vault-server.key.pem"
  tls_client_ca_file = "/etc/vault/vault-server.ca.crt.pem"
}

storage "gcs" {
  bucket           = "${storage_bucket}"
  credentials_file = "/etc/vault/gcp_credentials.json"
  ha_enabled       = "${ha_enabled}"
}

seal "gcpckms" {
  credentials = "/etc/vault/gcp_credentials.json"
  project     = "harmonic-vault"
  region      = "global"
  key_ring    = "vault"
  crypto_key  = "vault-auto-unseal"
}

ui = true