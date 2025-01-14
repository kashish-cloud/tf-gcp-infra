provider "google" {
  credentials = file("/Users/kashishdesai/Downloads/tf-gcp-infra-project-b207c7f5b113.json")
  project     = "tf-gcp-infra-project"
  region      = "us-east1"
}

resource "google_project_service" "servicenetworking" {
  project = "tf-gcp-infra-project"
  service = "servicenetworking.googleapis.com"
}

resource "google_compute_network" "my_vpc" {
  name                            = "my-vpc"
  auto_create_subnetworks         = false
  routing_mode                    = "REGIONAL"
  delete_default_routes_on_create = true

  depends_on = [google_project_service.servicenetworking]
}

resource "google_compute_subnetwork" "webapp_subnet" {
  name          = "webapp-subnet"
  ip_cidr_range = "10.0.1.0/24"
  network       = google_compute_network.my_vpc.self_link
}

resource "google_compute_subnetwork" "db_subnet" {
  name          = "db-subnet"
  ip_cidr_range = "10.0.2.0/24"
  network       = google_compute_network.my_vpc.self_link
}

resource "google_compute_route" "route_webapp_subnet" {
  name             = "route-webapp-subnet"
  network          = google_compute_network.my_vpc.self_link
  dest_range       = "0.0.0.0/0"
  next_hop_gateway = "default-internet-gateway"
  priority         = 1000

  depends_on = [google_compute_network.my_vpc]
}

resource "google_compute_global_address" "private_service_ip_range" {
  name          = "private-service-ip-range"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  network       = google_compute_network.my_vpc.self_link
  prefix_length = 24
  depends_on    = [google_compute_network.my_vpc]
}

resource "google_service_networking_connection" "private_connection" {
  network                 = google_compute_network.my_vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_service_ip_range.name]
  depends_on              = [google_compute_network.my_vpc]
}

resource "google_compute_firewall" "app_firewall" {
  name    = "app-firewall"
  network = google_compute_network.my_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = [8080, 22]
  }

  # Restricting traffic to only come from the load balancer's health check IP range
  source_ranges = [module.gce-lb-http.external_ip]
  target_tags   = ["application"]
}

resource "google_compute_disk" "app_disk" {
  name = "app-disk"
  size = 100
  type = "pd-standard"
  zone = "us-east1-c"
}

# CloudSQL Instance
resource "google_sql_database_instance" "cloudsql_instance" {
  name             = "webapp-db-instance"
  database_version = "POSTGRES_15"
  project          = "tf-gcp-infra-project"
  region           = "us-east1"

  encryption_key_name = google_kms_crypto_key.cloudsql_crypto_key.id

  depends_on = [
    google_service_networking_connection.private_connection,
    google_kms_crypto_key.cloudsql_crypto_key,
  google_kms_crypto_key_iam_binding.cloudsql_crypto_key_binding]

  settings {
    tier              = "db-f1-micro"
    activation_policy = "ALWAYS"
    disk_type         = "pd-ssd"
    disk_size         = 100

    # Link to custom VPC and subnet
    ip_configuration {
      ipv4_enabled    = false
      private_network = google_compute_network.my_vpc.self_link
    }
  }
  deletion_protection = false
}

# CloudSQL Database
resource "google_sql_database" "cloudsql_database" {
  name     = "webapp"
  instance = google_sql_database_instance.cloudsql_instance.name
}

# CloudSQL Database User
resource "random_password" "database_password" {
  length  = 16
  special = true
}

resource "google_sql_user" "cloudsql_user" {
  name     = "webapp"
  instance = google_sql_database_instance.cloudsql_instance.name
  password = random_password.database_password.result
}

resource "google_service_account" "ops_agent_service_account" {
  account_id   = "ops-agent-service-account"
  display_name = "Ops Agent Service Account"
  project      = "tf-gcp-infra-project"
}

resource "google_project_iam_binding" "ops_agent_logging_binding" {
  project = "tf-gcp-infra-project"
  role    = "roles/logging.admin"

  members = [
    "serviceAccount:${google_service_account.ops_agent_service_account.email}"
  ]
}

resource "google_project_iam_binding" "ops_agent_monitoring_binding" {
  project = "tf-gcp-infra-project"
  role    = "roles/monitoring.metricWriter"

  members = [
    "serviceAccount:${google_service_account.ops_agent_service_account.email}"
  ]
}

resource "google_project_iam_binding" "ops_agent_pubsub_publisher_binding" {
  project = "tf-gcp-infra-project"
  role    = "roles/pubsub.publisher"

  members = [
    "serviceAccount:${google_service_account.ops_agent_service_account.email}"
  ]
}

# Creating a new service account for Pub/Sub
resource "google_service_account" "pubsub_service_account" {
  account_id   = "pubsub-service-account"
  display_name = "Pub/Sub Service Account"
  project      = "tf-gcp-infra-project"
}

resource "google_project_iam_binding" "pubsub_publisher_binding" {
  project = "tf-gcp-infra-project"
  role    = "roles/pubsub.publisher"

  members = [
    "serviceAccount:${google_service_account.pubsub_service_account.email}"
  ]
}

resource "google_compute_region_instance_template" "webapp_template" {
  name        = "webapp-template"
  description = "Instance template for the web application"

  tags = ["application"]

  labels = {
    environment = "production"
  }

  machine_type = "n1-standard-1"

  // Create a new boot disk from an image
  disk {
    source_image = "projects/tf-gcp-infra-project/global/images/packer-1713151490"
    auto_delete  = true
    boot         = true
    disk_encryption_key {
      kms_key_self_link = google_kms_crypto_key.vm_crypto_key.id
    }
  }

  network_interface {
    network    = google_compute_network.my_vpc.self_link
    subnetwork = google_compute_subnetwork.webapp_subnet.self_link
    access_config {

    }
  }

  service_account {
    email  = google_service_account.ops_agent_service_account.email
    scopes = ["https://www.googleapis.com/auth/logging.admin", "https://www.googleapis.com/auth/cloud-platform", "https://www.googleapis.com/auth/pubsub"]
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    # Startup script to configure database connection for web application
    echo "HOST='${google_sql_database_instance.cloudsql_instance.private_ip_address}'" > /opt/webapp/.env
    echo "DBPORT=5432" >> /opt/webapp/.env
    echo "DBNAME='${google_sql_database.cloudsql_database.name}'" >> /opt/webapp/.env
    echo "DBUSER='${google_sql_user.cloudsql_user.name}'" >> /opt/webapp/.env
    echo "DBPASSWORD='${google_sql_user.cloudsql_user.password}'" >> /opt/webapp/.env
    systemctl start kas.service
    EOF

  depends_on = [
    google_kms_crypto_key.vm_crypto_key,
    google_kms_crypto_key_iam_binding.vm_crypto_key_binding
  ]
}

resource "google_dns_record_set" "example" {
  name         = "kashishdesai.me."
  type         = "A"
  ttl          = 300
  managed_zone = "kashishdesai"

  rrdatas = [
    module.gce-lb-http.external_ip
  ]
}

// Create Pub/Sub topic for email verification
resource "google_pubsub_topic" "verify_email" {
  name = "verify-email"
}

// Create subscription for the Cloud Function
resource "google_pubsub_subscription" "verify_email_subscription" {
  name                 = "verify-email-subscription"
  topic                = google_pubsub_topic.verify_email.name
  ack_deadline_seconds = 10

  expiration_policy {
    ttl = "604800s" // 7 days in seconds
  }
}

// Bind IAM roles for Cloud Function
resource "google_project_iam_binding" "cloud_function_invoker_binding" {
  project = "tf-gcp-infra-project"
  role    = "roles/cloudfunctions.invoker"

  members = [
    "serviceAccount:${google_service_account.pubsub_service_account.email}"
  ]
}

terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 4.34.0"
    }
  }
}

resource "random_id" "bucket_prefix" {
  byte_length = 8
}

resource "google_storage_bucket" "serverless_bucket" {
  name                        = "${random_id.bucket_prefix.hex}-gcf-source"
  location                    = "us-east1"
  uniform_bucket_level_access = true
  encryption {
    default_kms_key_name = google_kms_crypto_key.bucket_crypto_key.id
  }
  depends_on = [
    google_kms_crypto_key.bucket_crypto_key,
    google_kms_crypto_key_iam_binding.bucket_crypto_key_binding
  ]
}

data "archive_file" "serverless_code" {
  type        = "zip"
  output_path = "${path.module}/serverless.zip"
  source_dir  = "${path.module}/serverless"
}

resource "google_storage_bucket_object" "serverless_code" {
  name   = "serverless.zip"
  bucket = google_storage_bucket.serverless_bucket.name
  source = "serverless.zip"
}

resource "google_vpc_access_connector" "serverless_vpc_connector" {
  name          = "my-vpc-connector"
  region        = "us-east1"
  network       = google_compute_network.my_vpc.self_link
  ip_cidr_range = "10.0.0.0/28"

  depends_on = [google_compute_network.my_vpc]
}

// Deploy Cloud Function
resource "google_cloudfunctions2_function" "cloud_function" {
  name        = "verify-email-function"
  location    = "us-east1"
  description = "A new function"

  build_config {
    runtime     = "nodejs16"
    entry_point = "verifyEmailFunction"
    source {
      storage_source {
        bucket = google_storage_bucket.serverless_bucket.name
        object = google_storage_bucket_object.serverless_code.name
      }
    }
  }

  service_config {
    max_instance_count = 3
    min_instance_count = 1
    available_memory   = "256M"
    timeout_seconds    = 60
    environment_variables = {
      DB_HOST     = google_sql_database_instance.cloudsql_instance.private_ip_address
      DB_PORT     = "5432"
      DB_NAME     = google_sql_database.cloudsql_database.name
      DB_USER     = google_sql_user.cloudsql_user.name
      DB_PASSWORD = google_sql_user.cloudsql_user.password
    }
    ingress_settings               = "ALLOW_INTERNAL_ONLY"
    all_traffic_on_latest_revision = true
    vpc_connector                  = google_vpc_access_connector.serverless_vpc_connector.id
    service_account_email          = google_service_account.pubsub_service_account.email
  }

  event_trigger {
    trigger_region = "us-east1"
    event_type     = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic   = google_pubsub_topic.verify_email.id
    retry_policy   = "RETRY_POLICY_DO_NOT_RETRY"
  }
}

resource "google_compute_region_autoscaler" "my_autoscaler" {
  name   = "my-region-autoscaler"
  region = "us-east1"
  target = google_compute_region_instance_group_manager.my_instance_group_manager.id

  autoscaling_policy {
    max_replicas    = 5
    min_replicas    = 1
    cooldown_period = 60

    cpu_utilization {
      target = 0.05
    }
  }
}

resource "google_compute_health_check" "webapp_health_check" {
  name        = "webapp-health-check"
  description = "Health check for the web application"

  timeout_sec         = 1
  check_interval_sec  = 5
  healthy_threshold   = 4
  unhealthy_threshold = 5

  http_health_check {
    port         = 8080
    request_path = "/healthz"
  }
}

resource "google_compute_region_instance_group_manager" "my_instance_group_manager" {
  name = "my-instance-group-manager"

  base_instance_name = "application"
  region             = "us-east1"

  version {
    instance_template = google_compute_region_instance_template.webapp_template.id
  }

  named_port {
    name = "http"
    port = 8080
  }
}

module "gce-lb-http" {
  source  = "terraform-google-modules/lb-http/google"
  version = "~> 10.0"
  name    = "my-load-balancer"
  project = "tf-gcp-infra-project"

  firewall_networks = [
    google_compute_network.my_vpc.id,
  ]

  http_forward = false

  backends = {
    default = {
      protocol    = "HTTP"
      port        = 8080
      port_name   = "http"
      timeout_sec = 30
      enable_cdn  = false

      health_check = {
        request_path = "/healthz"
        port         = 8080
      }

      log_config = {
        enable      = true
        sample_rate = 1.0
      }

      groups = [
        {
          group = google_compute_region_instance_group_manager.my_instance_group_manager.instance_group
        },
      ]

      iap_config = {
        enable = false
      }
    }
  }

  ssl                             = true
  managed_ssl_certificate_domains = ["kashishdesai.me."]
}

resource "random_id" "key_suffix" {
  byte_length = 8
}

resource "google_kms_key_ring" "my_key_ring" {
  name     = "my-key-ring-${random_id.key_suffix.hex}"
  project  = "tf-gcp-infra-project"
  location = "us-east1"
}

resource "google_kms_crypto_key" "vm_crypto_key" {
  name            = "vm-cmek-key"
  key_ring        = google_kms_key_ring.my_key_ring.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "2592000s"
  depends_on      = [google_kms_key_ring.my_key_ring]
  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key" "cloudsql_crypto_key" {
  name            = "cloudsql-cmek-key"
  key_ring        = google_kms_key_ring.my_key_ring.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "2592000s"
  depends_on      = [google_kms_key_ring.my_key_ring]
  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key" "bucket_crypto_key" {
  name            = "bucket-cmek-key"
  key_ring        = google_kms_key_ring.my_key_ring.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "2592000s"
  depends_on      = [google_kms_key_ring.my_key_ring]
  lifecycle {
    prevent_destroy = false
  }
}

resource "google_kms_crypto_key_iam_binding" "vm_crypto_key_binding" {
  crypto_key_id = google_kms_crypto_key.vm_crypto_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:service-912452358996@compute-system.iam.gserviceaccount.com",
  ]
  depends_on = [google_kms_crypto_key.vm_crypto_key]
}

resource "google_project_service_identity" "gcp_sa_cloud_sql" {
  provider = google-beta
  project  = "tf-gcp-infra-project"
  service  = "sqladmin.googleapis.com"
}

resource "google_kms_crypto_key_iam_binding" "cloudsql_crypto_key_binding" {
  provider      = google-beta
  crypto_key_id = google_kms_crypto_key.cloudsql_crypto_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:${google_project_service_identity.gcp_sa_cloud_sql.email}"
  ]
  depends_on = [google_kms_crypto_key.cloudsql_crypto_key, google_project_service_identity.gcp_sa_cloud_sql]
}

resource "google_kms_crypto_key_iam_binding" "bucket_crypto_key_binding" {
  crypto_key_id = google_kms_crypto_key.bucket_crypto_key.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"

  members = [
    "serviceAccount:service-912452358996@gs-project-accounts.iam.gserviceaccount.com"
  ]
  depends_on = [google_kms_crypto_key.bucket_crypto_key, google_project_service.servicenetworking]
}
