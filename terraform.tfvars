# ─── Entra ID + Google Workspace SAML Federation — Terraform variable values ──
#
# Copy to terraform.tfvars and fill in real values, or set environment variables
# using the TF_VAR_<name> convention:
#
#   export TF_VAR_entra_tenant_id="..."
#   export TF_VAR_entra_client_secret="..."
#
# Sensitive values (secrets, certificates, tokens) should be injected via
# environment variables or a secrets manager — never committed to version control.
#
# This file documents every variable with its purpose, format, and where to
# find the value.

# ─── Microsoft Entra ID ──────────────────────────────────────────────────────
#
# A tenant-owned app registration with client-credentials flow is required for
# Graph API access. The app must be granted the following application roles:
#
#   User.ReadWrite.All
#   Domain.ReadWrite.All
#   Policy.Read.All
#   Policy.ReadWrite.SecurityDefaults
#   UserAuthenticationMethod.Read.All
#   UserAuthenticationMethod.ReadWrite.All
#   Domain-InternalFederation.ReadWrite.All
#
# Create the app in: Entra admin centre → App registrations → New registration
# Then: Certificates & secrets → New client secret
# Then: API permissions → Add permission → Microsoft Graph → Application permissions

# The Entra tenant ID (a UUID). Found in: Entra admin centre → Overview
entra_tenant_id = ""

# Client ID (application ID) of the tenant-owned app registration
entra_client_id = ""

# Client secret for the app registration (generated in Certificates & secrets)
entra_client_secret = ""

# Display name for the app registration — only used if creating a new one
app_display_name = "Infrastructure Sync"

# ISO 3166-1 alpha-2 country code for user licence usage location
# Common values: GB (United Kingdom), US (United States), DE (Germany)
usage_location = "GB"

# Domains that authenticate via the external SAML identity provider (Google).
# Users with email addresses in these domains will be created as federated
# Entra users with onPremisesImmutableId set to their Google Directory ID.
federated_domains = ["example.com"]

# Domains managed directly in Entra (no federation). Users in these domains
# authenticate with Entra-native passwords. Can be empty.
managed_domains = ["example.onmicrosoft.com"]

# Whether to enable Entra security defaults. Set to false when the external
# IdP handles MFA (Google Workspace in this case).
security_defaults_enabled = false

# ─── Google Workspace ────────────────────────────────────────────────────────
#
# OAuth2 credentials for the Google Admin Directory API. These are used to:
#   1. Look up user IDs (googleworkspace provider)
#   2. Manage custom user attributes (terracurl_request)
#   3. Manage directory schemas (googleworkspace_schema)
#
# Required OAuth scopes:
#   admin.directory.user.readonly
#   admin.directory.user
#   admin.directory.userschema
#
# Create OAuth credentials in: Google Admin Console → Security → API Controls
#   → Manage Domain-wide Delegation (or Google Cloud Console → APIs & Services
#   → Credentials → OAuth 2.0 Client ID)

# Google Workspace customer ID. Use "my_customer" for your own domain,
# or the customer ID from the Google Admin Console.
google_customer_id = "my_customer"

# OAuth2 client ID from Google Cloud Console credentials
google_oauth_client_id = ""

# OAuth2 client secret from Google Cloud Console credentials
google_oauth_client_secret = ""

# OAuth2 refresh token — obtained by authorising the OAuth2 client against
# the Google Admin Directory API scopes. See Google's OAuth2 documentation:
# https://developers.google.com/identity/protocols/oauth2
google_oauth_refresh_token = ""

# ─── Google SAML Application (Identity Provider) ─────────────────────────────
#
# These values come from the Google Admin Console SAML app configuration
# (Google Admin Console → Apps → Web and mobile apps → Office 365).
#
# The SAML app must be configured with:
#   ACS URL:               https://login.microsoftonline.com/login.srf
#   Entity ID:             urn:federation:MicrosoftOnline
#   Name ID Format:        PERSISTENT
#   Name ID:               Primary email (or custom attribute)
#   Attribute Mapping:     Primary Email → IDPEmail
#   Signed Response:       Enabled

# The Google Identity Provider ID — found in the SAML app metadata URL:
# https://accounts.google.com/o/saml2?idpid=<THIS_VALUE>
google_idp_idpid = ""

# The X.509 signing certificate from the Google SAML app metadata (PEM format).
# Found in: Google Admin Console → Apps → Office 365 → Setup information
# → "Download metadata" or copy the certificate directly.
google_idp_signing_certificate = ""

# ─── Users ───────────────────────────────────────────────────────────────────
#
# List of users to provision in both Google Workspace and Entra ID.
# Each user must already exist in Google Workspace — the terraform config
# looks up their stable Google Directory ID via the googleworkspace_user
# data source to use as the SAML ImmutableID.
#
# Users are automatically classified as federated or managed based on their
# email domain matching the federated_domains / managed_domains lists.
#
# Example:
users = [
  { email = "alice@example.com", full_name = "Alice Smith" },
  { email = "bob@example.com", full_name = "Bob Jones" },
  # Federated user — email domain matches federated_domains
  { email = "admin@example.onmicrosoft.com", full_name = "Tenant Admin" },
  # Managed user — email domain matches managed_domains
]
