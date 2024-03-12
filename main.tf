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

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["app"]
}

resource "google_compute_disk" "app_disk" {
  name = "app-disk"
  size = 100
  type = "pd-standard"
  zone = "us-east1-b"
}

# CloudSQL Instance
resource "google_sql_database_instance" "cloudsql_instance" {
  name             = "webapp-db-instance"
  database_version = "POSTGRES_13"
  project          = "tf-gcp-infra-project"
  region           = "us-east1"

  depends_on = [google_service_networking_connection.private_connection]

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

resource "google_compute_instance" "app_instance" {
  name         = "app-instance"
  machine_type = "n1-standard-1"
  zone         = "us-east1-b"
  tags         = ["app"]

  boot_disk {
    initialize_params {
      image = "projects/tf-gcp-infra-project/global/images/packer-1709431081"
      size  = "100"
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = google_compute_network.my_vpc.self_link
    subnetwork = google_compute_subnetwork.webapp_subnet.self_link
    access_config {

    }
  }

  metadata_startup_script = <<-EOF
    #!/bin/bash
    # Startup script to configure database connection for web application
    echo "HOST=${google_sql_database_instance.cloudsql_instance.ip_address[0].ip_address}" > /opt/webapp/.env
    echo "DBPORT=5432" >> /opt/webapp/.env
    echo "DBNAME=${google_sql_database.cloudsql_database.name}" >> /opt/webapp/.env
    echo "DBUSER=${google_sql_user.cloudsql_user.name}" >> /opt/webapp/.env
    echo "DBPASSWORD=${random_password.database_password.result}" >> /opt/webapp/.env
    systemctl start kas.service
  EOF
}
