provider "google" {
  credentials = file("/Users/kashishdesai/Downloads/tf-gcp-infra-project-b207c7f5b113.json")
  project     = "tf-gcp-infra-project"
  region      = "us-east1"
}

resource "google_compute_network" "my_vpc" {
  name                    = "my-vpc"
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
  delete_default_routes_on_create = true
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
  name                    = "route-webapp-subnet"
  network                 = google_compute_network.my_vpc.self_link
  dest_range              = "0.0.0.0/0"
  next_hop_gateway        = "default-internet-gateway"
  priority                = 1000

  depends_on = [google_compute_network.my_vpc]
}

resource "google_compute_firewall" "app_firewall" {
  name    = "app-firewall"
  network = google_compute_network.my_vpc.self_link

  allow {
    protocol = "tcp"
    ports    = [8080]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["webapp"]
}

resource "google_compute_disk" "app_disk" {
  name  = "app-disk"
  size  = 100
  type  = "pd-standard"
  zone  = "us-east1-b"  # Replace with your desired zone
}

resource "google_compute_image" "custom_app_image" {
  name         = "custom-app-image"
  source_disk  = google_compute_disk.app_disk.id
  project      = "tf-gcp-infra-project"
}

resource "google_compute_instance" "app_instance" {
  name         = "app-instance"
  machine_type = "n1-standard-1"
  zone         = "us-east1-b"

  boot_disk {
    initialize_params {
      image = google_compute_image.custom_app_image.self_link
    }
  }

  network_interface {
    network = google_compute_network.my_vpc.self_link
    subnetwork = google_compute_subnetwork.webapp_subnet.self_link
  }
}