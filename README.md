# Terraform: Entra ID + Google Workspace SAML Federation

Terraform configuration for federating Microsoft Entra ID (Azure AD) domains to Google Workspace via SAML 2.0. Users in federated domains authenticate through Google — Entra delegates authentication entirely to the Google Workspace SAML identity provider.

## Architecture

```
User → Microsoft Entra ID (service provider)
     → SAML redirect → Google Workspace (identity provider)
     → Google authentication + MFA
     → SAML assertion → Entra ID (assertion consumer)
     → User signed in
```

## What This Manages

| Resource | Provider | Purpose |
|----------|----------|---------|
| App registration + service principal | `hashicorp/azuread` | Tenant-owned app for Graph API access |
| Graph API role assignments | `hashicorp/azuread` | `User.ReadWrite.All`, `Domain.ReadWrite.All`, etc. |
| Security defaults policy | `terraprovider/microsoft365wp` | Disable Entra security defaults (Google handles MFA) |
| Custom directory schema | `hashicorp/googleworkspace` | `microsoftEntra.immutableId` attribute for stable NameID |
| User custom attributes | `devops-rob/terracurl` | Populate each user's Google Directory ID as ImmutableID |
| Domain federation | `devops-rob/terracurl` | SAML 2.0 federation config via Graph API |
| Entra users | `hashicorp/azuread` | Federated and managed users with ImmutableID |
| Random passwords | `hashicorp/random` | One-shot initial passwords |

## Prerequisites

### Microsoft Entra ID

1. **App registration** with client-credentials flow (or let Terraform create one via the `azuread_application` resource)
2. **Application permissions** on the app:
   - `User.ReadWrite.All`
   - `Domain.ReadWrite.All`
   - `Policy.Read.All`
   - `Policy.ReadWrite.SecurityDefaults`
   - `UserAuthenticationMethod.Read.All`
   - `UserAuthenticationMethod.ReadWrite.All`
   - `Domain-InternalFederation.ReadWrite.All`
3. **Verified domains** in the Entra tenant (federated domains must be added and verified before applying)

### Google Workspace

1. **OAuth2 credentials** with the following Admin Directory API scopes:
   - `admin.directory.user.readonly`
   - `admin.directory.user`
   - `admin.directory.userschema`
2. **SAML app** configured in Google Admin Console (Apps → Web and mobile apps → Office 365):
   - ACS URL: `https://login.microsoftonline.com/login.srf`
   - Entity ID: `urn:federation:MicrosoftOnline`
   - Name ID Format: `PERSISTENT`
   - Name ID: Primary email (or custom attribute for stable ImmutableID)
   - Attribute Mapping: `Primary Email` → `IDPEmail`
   - Signed Response: Enabled

   See [Google's official Office 365 SAML setup guide](https://support.google.com/a/answer/6363817) for step-by-step instructions.

### Why `terracurl_request`?

The `hashicorp/azuread` provider v3.x removed `azuread_domain` and `azuread_domain_federation` resources. Domain federation is configured via the Microsoft Graph API (`PUT /domains/{domain}/federationConfiguration/azureADTokenExchange`). Similarly, the `hashicorp/googleworkspace` provider (now archived) has no resource for partial user attribute updates. The `devops-rob/terracurl` provider fills both gaps with declarative HTTP resources that support create, read, and destroy lifecycle hooks.

## Usage

```bash
# Copy the example variables file and fill in your values
cp terraform.tfvars.example terraform.tfvars

# Initialise providers
terraform init

# Preview changes
terraform plan

# Apply
terraform apply
```

### Environment Variables

Alternatively, set variables via environment variables (recommended for CI/CD):

```bash
export TF_VAR_entra_tenant_id="..."
export TF_VAR_entra_client_id="..."
export TF_VAR_entra_client_secret="..."
export TF_VAR_google_oauth_client_id="..."
export TF_VAR_google_oauth_client_secret="..."
export TF_VAR_google_oauth_refresh_token="..."
export TF_VAR_google_idp_signing_certificate="..."
```

## ImmutableID Strategy

Each federated user's `onPremisesImmutableId` is set to their Google Directory `id` — a stable numeric string that never changes, even if the user's primary email is renamed. This avoids the "cannot update SourceAnchor for federated user" restriction in Entra.

The flow:
1. `googleworkspace_schema` creates a `microsoftEntra` custom schema with an `immutableId` field
2. `terracurl_request` populates each user's `immutableId` with their Google Directory `id`
3. The Google SAML app NameID can be configured to emit this attribute instead of Primary Email
4. `azuread_user` sets `onpremises_immutable_id` to the same Google `id`

## Caveats

- **Google SAML app is manual** — no Terraform provider can configure it (Google Admin Console uses Polymer/shadow DOM with no public API for SAML apps)
- **ImmutableID changes require federation teardown** — updating `onPremisesImmutableId` for a federated user fails with "cannot update SourceAnchor". You must temporarily remove federation, update the user, then recreate federation. This is handled automatically by [InfraSync's convergence guards](https://github.com/example/infrasync) but has no Terraform equivalent
- **Auth method enforcement** — preventing users from registering Microsoft-side MFA methods (Microsoft Authenticator, phone, etc.) requires the tenant-wide authentication methods policy, which `microsoft365wp_authentication_methods_policy` can manage but is not included in this example

## Providers

| Provider | Version | Purpose |
|----------|---------|---------|
| `hashicorp/azuread` | ~> 3.0 | Entra users, app registration, service principals |
| `hashicorp/googleworkspace` | ~> 0.7 | Custom directory schemas, user lookups |
| `terraprovider/microsoft365wp` | ~> 0.18 | Security defaults, authentication methods policy |
| `devops-rob/terracurl` | ~> 2.0 | HTTP API calls (domain federation, custom attributes) |
| `hashicorp/random` | ~> 3.6 | Password generation |

## References

- [Google Workspace: Set up single sign-on (SSO) for Office 365](https://support.google.com/a/answer/6363817)
- [Microsoft Graph: internalDomainFederation](https://learn.microsoft.com/en-us/graph/api/resources/internaldomainfederation)
- [Microsoft Graph: identitySecurityDefaultsEnforcementPolicy](https://learn.microsoft.com/en-us/graph/api/resources/identitysecuritydefaultsenforcementpolicy)
- [Microsoft Entra: sourceAnchor design concepts](https://learn.microsoft.com/en-us/entra/identity/hybrid/connect/plan-connect-design-concepts)
- [Google Admin Directory API: custom schemas](https://developers.google.com/workspace/admin/directory/v1/guides/manage-schemas)

## License

MIT
