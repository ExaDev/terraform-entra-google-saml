# Terraform: Entra ID + Google Workspace SAML Federation

[![GitHub](https://img.shields.io/badge/GitHub-181717?logo=github&logoColor=white)](https://github.com/ExaDev/terraform-entra-google-saml) [![CI](https://img.shields.io/github/actions/workflow/status/ExaDev/terraform-entra-google-saml/ci.yml?branch=main)](https://github.com/ExaDev/terraform-entra-google-saml/actions)

Terraform configuration for federating Microsoft Entra ID (Azure AD) domains to Google Workspace via SAML 2.0. Users in federated domains authenticate through Google. Entra delegates authentication entirely to the Google Workspace SAML identity provider.

## Why?

If your organisation uses Google Workspace for email, calendar, and file storage, most of your users never interact with Microsoft services directly. But many enterprises still need Microsoft accounts for Azure, Microsoft 365, Power Platform, Visual Studio, or partner ecosystems that require Entra ID credentials.

Without federation, every user maintains two separate identities with two separate passwords and two separate MFA registrations. This means:

- **Credential fatigue**: users manage two sets of credentials, leading to weaker passwords and more helpdesk resets
- **MFA conflicts**: Microsoft pushes Microsoft Authenticator; Google pushes Google's MFA. Users get confused about which to use when
- **Provisioning overhead**: creating and deprovisioning users in two directories manually, with no guarantee they stay in sync
- **Security gaps**: offboarded users may linger in one directory while being removed from the other

Federation solves this by making Google the single source of truth for authentication. When a user signs in to a Microsoft service:

1. Microsoft redirects them to Google
2. Google authenticates them (with MFA enforced by Google's policies)
3. Google sends a SAML assertion back to Microsoft
4. Microsoft trusts the assertion and signs the user in

The result: **one identity, one password, one MFA prompt**, enforced by Google and trusted by Microsoft.

### Why not the other direction (Microsoft as IdP for Google)?

Google Workspace has no equivalent of Entra's domain federation. You can't redirect `@example.com` sign-ins from Google to Microsoft. The federation direction is dictated by which system owns the email domain's MX records. If Google handles your mail, Google must be the IdP.

### Why not Azure AD Connect (directory synchronisation)?

Azure AD Connect synchronises an on-premises Active Directory to Entra, but it requires a Windows Server running the sync agent. For organisations that are cloud-native (no on-premises AD), SAML federation is the correct approach: no sync agent, no password hash synchronisation, no server to maintain.

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
| Domain creation + verification | `devops-rob/terracurl` | Add domains to tenant, retrieve DNS records, verify ownership |
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
3. Domains are created and verified by this Terraform config (see Usage below for the two-pass apply process)

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

### First-time setup (two-pass apply)

Domain verification requires adding DNS records between Terraform passes:

```bash
# Initialise providers
terraform init

# First pass: create domains, output verification DNS records
terraform apply -target=terracurl_request.domain -target=data.terracurl_request.domain_verification_records

# Review the domain_verification_records output. Add the TXT records
to your DNS zone for each domain.

# Second pass: verify domains and create all remaining resources
terraform apply
```

### Subsequent applies

Once domains are verified, a single `terraform apply` handles everything:

```bash
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

Each federated user's `onPremisesImmutableId` is set to their Google Directory `id`, a stable numeric string that never changes even if the user's primary email is renamed. This avoids the "cannot update SourceAnchor for federated user" restriction in Entra.

The flow:
1. `googleworkspace_schema` creates a `microsoftEntra` custom schema with an `immutableId` field
2. `terracurl_request` populates each user's `immutableId` with their Google Directory `id`
3. The Google SAML app NameID can be configured to emit this attribute instead of Primary Email
4. `azuread_user` sets `onpremises_immutable_id` to the same Google `id`

## Caveats

- **Google SAML app is manual**: no Terraform provider can configure it (Google Admin Console uses Polymer/shadow DOM with no public API for SAML apps)
- **ImmutableID changes require federation teardown**: updating `onPremisesImmutableId` for a federated user fails with "cannot update SourceAnchor". You must temporarily remove federation, update the user, then recreate federation. There is no Terraform-native mechanism for this.
- **Auth method enforcement**: preventing users from registering Microsoft-side MFA methods (Microsoft Authenticator, phone, etc.) requires the tenant-wide authentication methods policy, which `microsoft365wp_authentication_methods_policy` can manage but is not included in this example

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
