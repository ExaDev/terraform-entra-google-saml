terraform {
  required_version = ">= 1.7"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.0"
    }
    googleworkspace = {
      source  = "hashicorp/googleworkspace"
      version = "~> 0.7"
    }
    microsoft365wp = {
      source  = "terraprovider/microsoft365wp"
      version = "~> 0.18"
    }
    terracurl = {
      source  = "devops-rob/terracurl"
      version = "~> 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }

  # Uncomment for remote state:
  # backend "s3" {
  #   bucket = "example-terraform-state"
  #   key    = "federation/terraform.tfstate"
  #   region = "eu-west-2"
  # }
}

# ─── Entra ID provider (service principal, client-credentials) ────────────────

provider "azuread" {
  tenant_id     = var.entra_tenant_id
  client_id     = var.entra_client_id
  client_secret = var.entra_client_secret
}

# ─── Google Workspace provider ────────────────────────────────────────────────
#
# Authenticated via access token obtained from the Google OAuth2 token endpoint.
# The googleworkspace provider accepts either a credentials file (service account)
# or an access_token string. We use the token from the terracurl data source so
# the same refresh token flow serves both the provider and the custom attribute
# PATCH requests.

provider "googleworkspace" {
  access_token = jsondecode(data.terracurl_request.google_token.response).access_token
  customer_id  = var.google_customer_id
}

# ─── Microsoft 365 Workforce Portal provider ──────────────────────────────────
#
# Terraform provider for Microsoft 365, leveraging the Microsoft Graph API.
# Manages Entra policies, authentication methods, and identity configuration
# that the hashicorp/azuread provider doesn't cover.
#
# Uses the same service principal credentials as the azuread provider.

provider "microsoft365wp" {
  tenant_id     = var.entra_tenant_id
  client_id     = var.entra_client_id
  client_secret = var.entra_client_secret
}
