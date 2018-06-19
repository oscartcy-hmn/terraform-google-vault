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

variable region {
  default = "us-central1"
}

variable zone {
  default = "us-central1-b"
}

variable project_id {}
variable storage_bucket {}
variable kms_keyring_name {}

variable ha_enabled {
  default = "false"
}

variable ha_size {
  default = "1"
}

variable vault_license_key {
  description = "Vault license key"
  default = ""
}

variable vault_image {
  description = "Vault image file name"
  default = ""
}

variable api_addr {
  description = "Vault API address"
  default = ""
}

provider google {
  region = "${var.region}"
}

module "vault" {
  // source               = "github.com/GoogleCloudPlatform/terraform-google-vault"
  source               = "../../"
  project_id           = "${var.project_id}"
  region               = "${var.region}"
  zone                 = "${var.zone}"
  machine_type         = "n1-standard-4"
  storage_bucket       = "${var.storage_bucket}"
  kms_keyring_name     = "${var.kms_keyring_name}"
  force_destroy_bucket = true
  ha_enabled           = "${var.ha_enabled}"
  ha_size              = "${var.ha_size}"
  vault_image          = "${var.vault_image}"
  vault_license_key    = "${var.vault_license_key}"
  api_addr             = "${var.api_addr}"
}
