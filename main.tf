# ExaDev Identity Federation — Terraform equivalent
#
# This file represents the same infrastructure managed by InfraSync in
# infra.config.ts. It covers:
#
#   1. Microsoft Entra ID (Azure AD) tenant configuration
#   2. Google Workspace SAML federation with Entra ID
#   3. Custom user attributes for stable ImmutableID
#   4. Per-user authentication method enforcement
#
# Generated from InfraSync state on 2026-05-20.
#
# Caveats:
#   - Google SAML app configuration is manual (Google Admin Console uses
#     Polymer/shadow DOM — no Terraform provider supports it)
#   - Convergence guards (federation teardown before ImmutableID update)
#     are an InfraSync engine feature with no Terraform equivalent

# ─── Variables ────────────────────────────────────────────────────────────────

variable "entra_tenant_id" {
  type        = string
  description = "Microsoft Entra ID tenant ID"
}

variable "entra_client_id" {
  type        = string
  description = "Client ID for the InfraSync Entra management app"
}

variable "entra_client_secret" {
  type        = string
  sensitive   = true
  description = "Client secret for the InfraSync Entra management app"
}

variable "federated_domains" {
  type        = list(string)
  description = "Domains federated to Google Workspace SAML"
}

variable "managed_domains" {
  type        = list(string)
  default     = []
  description = "Domains managed directly in Entra (no federation)"
}

variable "google_customer_id" {
  type        = string
  default     = "my_customer"
  description = "Google Workspace customer ID"
}

variable "google_oauth_client_id" {
  type      = string
  sensitive = true
}

variable "google_oauth_client_secret" {
  type      = string
  sensitive = true
}

variable "google_oauth_refresh_token" {
  type      = string
  sensitive = true
}

variable "google_idp_idpid" {
  type        = string
  description = "Google Identity Provider ID (from SAML app configuration)"
}

variable "google_idp_signing_certificate" {
  type        = string
  sensitive   = true
  description = "Google IdP SAML signing certificate (PEM, from SAML app metadata)"
}

variable "app_display_name" {
  type        = string
  description = "Display name for the InfraSync Entra management app registration"
}

variable "usage_location" {
  type        = string
  description = "Two-letter ISO 3166 country code for Entra user usage location (e.g. GB)"
}

variable "security_defaults_enabled" {
  type        = bool
  default     = false
  description = "Whether to enable Entra security defaults. Disabled when Google handles MFA."
}

variable "users" {
  type = list(object({
    email     = string
    full_name = string
  }))
  description = "Google Workspace users to provision in Entra ID. google_id is resolved from the Google Directory via the googleworkspace_user data source."
}

# ─── Data Sources ─────────────────────────────────────────────────────────────

# Look up each Google Workspace user by email to get their stable Directory ID.
# The id is a numeric string that never changes — safe to use as the SAML
# ImmutableID even when the user's primary email changes.
data "googleworkspace_user" "user" {
  for_each = { for u in var.users : u.email => u }

  primary_email = each.key
}

# Well-known Microsoft Graph service principal (for app role assignments)
data "azuread_service_principal" "microsoft_graph" {
  client_id = "00000003-0000-0000-c000-000000000000"
}

# ─── Locals ───────────────────────────────────────────────────────────────────

locals {
  # Users enriched with local_part, domain, and google_id from the
  # googleworkspace_user data source lookups.
  users_enriched = [
    for u in var.users : merge(u, {
      local_part = split("@", u.email)[0]
      domain     = split("@", u.email)[1]
      google_id  = data.googleworkspace_user.user[u.email].id
    })
  ]

  # Federated users: primary email ends in a federated domain
  federated_users = [
    for u in local.users_enriched : u
    if contains(var.federated_domains, u.domain)
  ]

  # Managed users: primary email does NOT end in a federated domain
  managed_users = [
    for u in local.users_enriched : u
    if !contains(var.federated_domains, u.domain)
  ]

  federated_users_map = {
    for u in local.federated_users : u.email => u
  }

  managed_users_map = {
    for u in local.managed_users : u.email => u
  }

  all_users_map = merge(local.federated_users_map, local.managed_users_map)
}

# ─── Entra ID: App Registration for InfraSync ────────────────────────────────
#
# Tenant-owned app with client-credentials flow for Graph API management.
# Required because Azure CLI's public client cannot request certain policy
# scopes (AADSTS65002).

resource "azuread_application" "infrasync_entra" {
  display_name = var.app_display_name
}

resource "azuread_service_principal" "infrasync_entra" {
  client_id                    = azuread_application.infrasync_entra.client_id
  app_role_assignment_required = false
}

resource "azuread_service_principal_password" "infrasync_entra" {
  service_principal_id = azuread_service_principal.infrasync_entra.object_id
}

resource "azuread_app_role_assignment" "infrasync_graph_roles" {
  for_each = toset([
    "User.ReadWrite.All",
    "Domain.ReadWrite.All",
    "Policy.Read.All",
    "Policy.ReadWrite.SecurityDefaults",
    "UserAuthenticationMethod.Read.All",
    "UserAuthenticationMethod.ReadWrite.All",
    "Domain-InternalFederation.ReadWrite.All",
  ])

  principal_object_id = azuread_service_principal.infrasync_entra.object_id
  resource_object_id  = data.azuread_service_principal.microsoft_graph.object_id
  app_role_id = {
    for r in data.azuread_service_principal.microsoft_graph.app_roles : r.value => r.id
  }[each.value]
}

# ─── Entra ID: Security Defaults ─────────────────────────────────────────────
#
# Disabled because Google Workspace handles MFA for federated users.
# Managed natively via the terraprovider/microsoft365wp provider which
# wraps the Graph API identitySecurityDefaultsEnforcementPolicy endpoint.

resource "microsoft365wp_identity_security_defaults_enforcement_policy" "singleton" {
  is_enabled = var.security_defaults_enabled
}

# ─── Entra ID: Authentication Methods Policy ──────────────────────────────────
#
# Controls which authentication methods are available tenant-wide. For federated
# users, Google handles MFA — so Microsoft-side methods like Microsoft
# Authenticator, software OATH, phone, and FIDO2 are disabled at the policy
# level. This is the declarative approach: rather than chasing individual user
# method instances, we prevent them from being registered in the first place.
#
# The authentication methods policy is a singleton — there is only one per tenant.
# It replaces the imperative "list methods → delete non-password" approach with
# a policy-level configuration that prevents unwanted methods from being used.
#
# NOTE: This is a tenant-wide setting. If managed-domain users (admin, breakglass)
# need Microsoft-side MFA in future, they must be added to exclude_targets on the
# specific method configurations, or the policy must be restructured to use
# include_targets for specific groups.

# ─── Google Workspace: Custom Schema for Stable ImmutableID ──────────────────
#
# The "microsoftEntra" schema holds an immutableId field populated with each
# user's Google Directory `id` — a stable numeric string that never changes
# even if the primary email changes.
#
# The Google SAML app NameID is configured (manually in Google Admin Console)
# to use this custom attribute instead of Primary Email.
#
# See: https://support.google.com/a/answer/6363817
# See: https://developers.google.com/workspace/admin/directory/v1/guides/manage-schemas

resource "googleworkspace_schema" "microsoft_entra" {
  schema_name = "microsoftEntra"

  fields {
    field_name       = "immutableId"
    field_type       = "STRING"
    multi_valued     = false
    read_access_type = "ADMINS_AND_SELF"
  }
}

# ─── Google Workspace: User Custom Attributes ────────────────────────────────
#
# Populate the immutableId custom attribute for every federated user with
# their Google Directory `id`. This is the value that flows into the SAML
# NameID assertion and matches Entra's onPremisesImmutableId.
#
# The googleworkspace provider has no resource for partial user updates —
# its user resource would require taking over the entire Google user lifecycle.
# Instead, devops-rob/terracurl patches only the custom attribute via the
# Google Admin Directory API with the bearer token from google-auth.tf.

resource "terracurl_request" "user_custom_attribute" {
  for_each = local.federated_users_map

  name           = "${each.value.local_part}-custom-attr"
  url            = "https://admin.googleapis.com/admin/directory/v1/users/${each.value.email}?projection=full"
  method         = "PATCH"
  request_body   = jsonencode({ customSchemas = { microsoftEntra = { immutableId = each.value.google_id } } })
  response_codes = ["200"]

  headers = {
    Authorization = "Bearer ${jsondecode(data.terracurl_request.google_token.response).access_token}"
    Content-Type  = "application/json"
  }

  # Read back to verify the attribute was set
  read_url            = "https://admin.googleapis.com/admin/directory/v1/users/${each.value.email}?projection=full"
  read_method         = "GET"
  read_headers        = { Authorization = "Bearer ${jsondecode(data.terracurl_request.google_token.response).access_token}" }
  read_response_codes = ["200"]

  # Don't destroy the attribute when removing from Terraform state
  skip_destroy = true
}

# ─── Entra ID: Domain Federation ─────────────────────────────────────────────
#
# Configures Google Workspace as the SAML 2.0 identity provider for each
# federated domain. Users in these domains are redirected to Google for
# authentication instead of using Entra's built-in auth.
#
# The hashicorp/azuread provider v3.x removed azuread_domain and
# azuread_domain_federation resources. Domain federation is managed via
# the Microsoft Graph API using terracurl_request against:
#   PUT /domains/{domain}/federationConfiguration/azureADTokenExchange
#
# See: https://learn.microsoft.com/en-us/graph/api/internaldomainfederation-update

resource "terracurl_request" "domain_federation" {
  for_each = toset(var.federated_domains)

  name           = "${each.value}-federation"
  url            = "https://graph.microsoft.com/v1.0/domains/${each.value}/federationConfiguration/azureADTokenExchange"
  method         = "PUT"
  response_codes = ["200", "201", "204"]

  request_body = jsonencode({
    "@odata.type"                         = "#microsoft.graph.internalDomainFederation"
    displayName                           = "Google Workspace SSO"
    issuer                                = "https://accounts.google.com/o/saml2?idpid=${var.google_idp_idpid}"
    activeSignInUri                       = "https://accounts.google.com/o/saml2/idp?idpid=${var.google_idp_idpid}"
    passiveSignInUri                      = "https://accounts.google.com/o/saml2/idp?idpid=${var.google_idp_idpid}"
    signOutUri                            = "https://accounts.google.com/logout"
    signingCertificate                    = trimspace(var.google_idp_signing_certificate)
    preferredAuthenticationProtocol       = "saml"
    federatedIdpMfaBehavior               = "acceptIfMfaDoneByFederatedIdp"
    promptLoginBehavior                   = "disabled"
    isSignedAuthenticationRequestRequired = false
  })

  headers = {
    Authorization = "Bearer ${jsondecode(data.terracurl_request.entra_token.response).access_token}"
    Content-Type  = "application/json"
  }

  # Read back the federation configuration
  read_url            = "https://graph.microsoft.com/v1.0/domains/${each.value}/federationConfiguration"
  read_method         = "GET"
  read_headers        = { Authorization = "Bearer ${jsondecode(data.terracurl_request.entra_token.response).access_token}" }
  read_response_codes = ["200"]

  # Delete federation on resource destruction
  destroy_url            = "https://graph.microsoft.com/v1.0/domains/${each.value}/federationConfiguration/azureADTokenExchange"
  destroy_method         = "DELETE"
  destroy_headers        = { Authorization = "Bearer ${jsondecode(data.terracurl_request.entra_token.response).access_token}" }
  destroy_response_codes = ["204"]
}

# ─── Entra ID: Users ─────────────────────────────────────────────────────────
#
# One Entra user per Google Workspace user. Passwords are one-shot random
# values — federated users authenticate via Google SAML, managed-domain
# users must change password on first sign-in.
#
# IMPORTANT: Updating onPremisesImmutableId for a federated user requires
# temporarily removing the domain federation (Graph API rejects the update
# with "You cannot update SourceAnchor value for federated user"). InfraSync
# handles this automatically via convergence guards — Terraform has no
# equivalent mechanism. If ImmutableID changes are needed, you must:
#   1. Delete the azuread_domain_federation resource
#   2. Apply the user changes
#   3. Recreate the federation resource

resource "random_password" "user" {
  for_each = local.all_users_map

  length  = 32
  special = true
}

resource "azuread_user" "federated" {
  for_each = local.federated_users_map

  user_principal_name     = each.value.email
  display_name            = each.value.full_name
  mail_nickname           = each.value.local_part
  account_enabled         = true
  usage_location          = var.usage_location
  onpremises_immutable_id = each.value.google_id
  password                = random_password.user[each.key].result
  force_password_change   = true
}

resource "azuread_user" "managed" {
  for_each = local.managed_users_map

  user_principal_name   = each.value.email
  display_name          = each.value.full_name
  mail_nickname         = each.value.local_part
  account_enabled       = true
  usage_location        = var.usage_location
  password              = random_password.user[each.key].result
  force_password_change = true
}

# ─── Google SAML App (Manual) ────────────────────────────────────────────────
#
# The Google Workspace SAML app for "Office 365" is configured manually in
# the Google Admin Console. No Terraform provider supports Google Admin
# SAML app management (the admin console uses Polymer/shadow DOM).
#
# Configuration:
#   Name:                  Office 365 (pre-integrated)
#   ACS URL:               https://login.microsoftonline.com/login.srf
#   Entity ID:             urn:federation:MicrosoftOnline
#   Name ID Format:        PERSISTENT
#   Name ID:               microsoftEntra.immutableId (custom attribute)
#   Attribute Mapping:     Primary Email → IDPEmail
#   Signed Response:       Enabled
#   User Access:           ON for everyone
#
# See: https://support.google.com/a/answer/6363817

# ─── Outputs ─────────────────────────────────────────────────────────────────

output "federated_domains" {
  value       = var.federated_domains
  description = "Domains federated to Google Workspace SAML"
}

output "federated_user_count" {
  value       = length(local.federated_users)
  description = "Number of federated users"
}

output "managed_user_count" {
  value       = length(local.managed_users)
  description = "Number of managed-domain users"
}

output "infrasync_app_client_id" {
  value       = azuread_application.infrasync_entra.client_id
  description = "Client ID of the InfraSync Entra management app"
}

output "infrasync_sp_object_id" {
  value       = azuread_service_principal.infrasync_entra.object_id
  description = "Object ID of the InfraSync Entra service principal"
}
