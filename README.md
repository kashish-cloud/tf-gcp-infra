# Terraform Infrastructure Setup for Google Cloud

This repository contains Terraform configurations to set up networking resources in Google Cloud, including a Virtual Private Cloud (VPC), subnets, and routes.

## Prerequisites

Before you begin, make sure you have the following installed on your machine:

- [Google Cloud SDK](https://cloud.google.com/sdk/docs/install)
- [Terraform](https://learn.hashicorp.com/tutorials/terraform/install-cli)

## Setup Instructions

### 1. Install and Configure gcloud CLI

Make sure you have the gcloud CLI installed and configured with the correct credentials.

```bash
gcloud auth login
```

Configure Variables:

provider "google" {
credentials = file("/path/to/your/credentials.json")
project = "your-project-id"
region = "your-region"
}

terraform init
terraform apply
