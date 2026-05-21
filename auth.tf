# ─── OAuth Token Data Sources ─────────────────────────────────────────────────
#
# Shared data sources that exchange credentials for access tokens.
# Referenced by provider blocks (versions.tf) and terracurl resources (main.tf).

# Google OAuth2 access token — used by the googleworkspace provider and
# terracurl_request custom attribute resources.
data "terracurl_request" "google_token" {
  name   = "google_oauth_token"
  url    = "https://oauth2.googleapis.com/token"
  method = "POST"

  request_body = jsonencode({
    client_id     = var.google_oauth_client_id
    client_secret = var.google_oauth_client_secret
    refresh_token = var.google_oauth_refresh_token
    grant_type    = "refresh_token"
  })

  response_codes = ["200"]
}

# Microsoft Entra access token (client-credentials flow) — used by
# terracurl_request resources for domain federation and other Graph API
# operations that the azuread and microsoft365wp providers don't cover.
#
# Requests the full set of Graph API scopes granted to the InfraSync app.
data "terracurl_request" "entra_token" {
  name   = "entra_oauth_token"
  url    = "https://login.microsoftonline.com/${var.entra_tenant_id}/oauth2/v2.0/token"
  method = "POST"

  request_body = jsonencode({
    client_id     = var.entra_client_id
    client_secret = var.entra_client_secret
    scope         = "https://graph.microsoft.com/.default"
    grant_type    = "client_credentials"
  })

  response_codes = ["200"]
}
