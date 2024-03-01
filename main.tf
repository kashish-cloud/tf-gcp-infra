provider "google" {
  credentials = file("/Users/kashishdesai/Downloads/tf-gcp-infra-project-b207c7f5b113.json")
  project     = "tf-gcp-infra-project"
  region      = "us-east1"
}

resource "google_project_service" "servicenetworking" {
  project = "tf-gcp-infra-project"
  service = "servicenetworking.googleapis.com"
}

resource "google_service_networking_connection" "private_connection" {
  network                 = google_compute_network.my_vpc.self_link
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = ["10.2.0.0/16"]
}

resource "google_project_iam_member" "add_peering_permission" {
  project = "tf-gcp-infra-project"
  role    = "roles/servicenetworking.servicesAdmin"
  member  = "serviceAccount:912452358996-compute@developer.gserviceaccount.com"
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

resource "google_compute_firewall" "db_firewall" {
  name    = "db-firewall"
  network = google_compute_network.my_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = [5432]
  }

  source_tags   = ["app"]
  target_tags   = ["db"]
  source_ranges = [google_compute_instance.app_instance.network_interface.0.access_config[0].nat_ip]
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
      image = "projects/tf-gcp-infra-project/global/images/packer-1709082053"
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
    echo "DB_HOST=${google_sql_database_instance.cloudsql_instance.ip_address}" >> /etc/environment
    echo "DB_PORT=5432" >> /etc/environment
    echo "DB_NAME=${google_sql_database.cloudsql_database.name}" >> /etc/environment
    echo "DB_USER=${google_sql_user.cloudsql_user.name}" >> /etc/environment
    echo "DB_PASSWORD=${random_password.database_password.result}" >> /etc/environment
    systemctl start kas.service
  EOF
}
