/*
 * Copyright 2017 Google Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *   http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

data "template_file" "vault-startup-script" {
  template = "${file("${format("%s/scripts/startup.sh.tpl", path.module)}")}"

  vars {
    config                = "${data.template_file.vault-config.rendered}"
    service_account_email = "${google_service_account.vault-admin.email}"
    vault_version         = "${var.vault_version}"
    vault_args            = "${var.vault_args}"
    assets_bucket         = "${google_storage_bucket.vault-assets.name}"
    kms_keyring_name      = "${var.kms_keyring_name}"
    kms_key_name          = "${var.kms_key_name}"
    vault_sa_key          = "${google_storage_bucket_object.vault-sa-key.name}"
    vault_tls_key         = "${google_storage_bucket_object.vault-tls-key.name}"
    vault_tls_cert        = "${google_storage_bucket_object.vault-tls-cert.name}"
    vault_license_key     = "${var.vault_license_key}"
    vault_image           = "${var.vault_image}"
    storage_bucket        = "${var.storage_bucket}"
  }
}

data "template_file" "vault-config" {
  template = "${file("${format("%s/scripts/config.hcl.tpl", path.module)}")}"

  vars {
    storage_bucket = "${var.storage_bucket}"
    ha_enabled     = "${var.ha_enabled}"
    region         = "${var.region}"
  }
}

module "vault-server" {
  source                = "github.com/GoogleCloudPlatform/terraform-google-managed-instance-group"
  http_health_check     = false
  region                = "${var.region}"
  zone                  = "${var.zone}"
  name                  = "vault-${var.region}"
  machine_type          = "${var.machine_type}"
  compute_image         = "debian-cloud/debian-9"
  service_account_email = "${google_service_account.vault-admin.email}"

  service_account_scopes = [
    "https://www.googleapis.com/auth/compute",
    "https://www.googleapis.com/auth/logging.write",
    "https://www.googleapis.com/auth/cloud-platform",
    "https://www.googleapis.com/auth/monitoring.write",
    "https://www.googleapis.com/auth/devstorage.full_control",
    "https://www.googleapis.com/auth/spanner.data",
  ]

  size              = "${var.ha_size}"
  service_port      = "80"
  service_port_name = "hc"
  startup_script    = "${data.template_file.vault-startup-script.rendered}"
  target_tags       = ["vault"]
}

resource "google_spanner_instance" "vault-instance" {
  config       = "regional-${var.region}"
  display_name = "vault-instance-${var.region}"
  name = "vault-instance-${var.region}"
  num_nodes = 1
}

resource "google_spanner_database" "vault-database" {
  instance  = "${google_spanner_instance.vault-instance.name}"
  name      = "vault-database-${var.region}"
  ddl       =  [
    "CREATE TABLE Vault ( Key STRING(MAX) NOT NULL, Value BYTES(MAX), ) PRIMARY KEY (Key)",
    "CREATE TABLE VaultHA ( Key STRING(MAX) NOT NULL, Value STRING(MAX), Identity STRING(36) NOT NULL, Timestamp TIMESTAMP NOT NULL, ) PRIMARY KEY (Key)"
  ]
}

resource "google_storage_bucket" "vault-assets" {
  name          = "${var.storage_bucket}-${var.region}-assets"
  location      = "${var.region}"
  storage_class = "REGIONAL"

  // delete bucket and contents on destroy.
  force_destroy = "${var.force_destroy_bucket}"
}

resource "google_service_account" "vault-admin" {
  account_id   = "vault-admin-${var.region}"
  display_name = "Vault Admin (${var.region})"
}

resource "google_service_account_key" "vault-admin" {
  service_account_id = "${google_service_account.vault-admin.id}"
  public_key_type = "TYPE_X509_PEM_FILE"
  private_key_type = "TYPE_GOOGLE_CREDENTIALS_FILE"
}

// Encrypt the SA key with KMS.
data "external" "sa-key-encrypted" {
  program = ["${path.module}/encrypt_file.sh"]

  query = {
    dest    = "vault_sa_key.json.encrypted.base64"
    data    = "${google_service_account_key.vault-admin.private_key}"
    keyring = "${var.kms_keyring_name}"
    key     = "${var.kms_key_name}"
    b64in   = "true"
  }
}

// Upload the service account key to the assets bucket.
resource "google_storage_bucket_object" "vault-sa-key" {
  name         = "vault_sa_key.json.encrypted.base64"
  content      = "${file(data.external.sa-key-encrypted.result["file"])}"
  content_type = "application/octet-stream"
  bucket       = "${google_storage_bucket.vault-assets.name}"
  
  provisioner "local-exec" {
    when    = "destroy"
    command = "rm -f vault_sa_key.json*"
    interpreter = ["sh", "-c"]
  }
}

resource "google_project_iam_policy" "vault" {
  project     = "${var.project_id}"
  policy_data = "${data.google_iam_policy.vault.policy_data}"
}

data "google_iam_policy" "vault" {
  binding {
    role = "roles/storage.admin"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }

  binding {
    role = "roles/iam.serviceAccountActor"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }

  binding {
    role = "roles/iam.serviceAccountKeyAdmin"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }

  binding {
    role = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }

  binding {
    role = "roles/logging.logWriter"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }

  binding {
    role = "roles/viewer"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }

  binding {
    role = "roles/spanner.databaseUser"

    members = [
      "serviceAccount:${google_service_account.vault-admin.email}",
    ]
  }
}

// TLS resources

// Encrypt the server key.
data "external" "vault-tls-key-encrypted" {
  program = ["${path.module}/encrypt_file.sh"]

  query = {
    dest    = "certs/vault-server.key.pem.encrypted.base64"
    data    = "vault-server.key.pem"
    keyring = "${var.kms_keyring_name}"
    key     = "${var.kms_key_name}"
  }
}

// Upload the server key to the assets bucket.
resource "google_storage_bucket_object" "vault-tls-key" {
  name         = "vault-server.key.pem.encrypted.base64"
  content      = "${file(data.external.vault-tls-key-encrypted.result["file"])}"
  content_type = "application/octet-stream"
  bucket       = "${google_storage_bucket.vault-assets.name}"
  
  provisioner "local-exec" {
    when    = "destroy"
    command = "rm -f certs/vault-server.key.pem*"
    interpreter = ["sh", "-c"]
  }
}

// Encrypt the server cert.
data "external" "vault-tls-cert-encrypted" {
  program = ["${path.module}/encrypt_file.sh"]

  query = {
    dest    = "certs/vault-server.crt.pem.encrypted.base64"
    data    = "vault-server.crt.pem"
    keyring = "${var.kms_keyring_name}"
    key     = "${var.kms_key_name}"
  }
}

// Upload the server key to the assets bucket.
resource "google_storage_bucket_object" "vault-tls-cert" {
  name         = "vault-server.crt.pem.encrypted.base64"
  content      = "${file(data.external.vault-tls-cert-encrypted.result["file"])}"
  content_type = "application/octet-stream"
  bucket       = "${google_storage_bucket.vault-assets.name}"
  
  provisioner "local-exec" {
    when    = "destroy"
    command = "rm -f certs/vault-server.crt.pem*"
    interpreter = ["sh", "-c"]
  }
}
