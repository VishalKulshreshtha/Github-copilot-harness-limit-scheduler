# Security and privacy notes

## Supported usage

Use this script only from a trusted administrator workstation or trusted automation host.

The script is intended for administrators who already have the required Power Platform permissions.

## Authentication

- Authentication uses the administrator context through `Az.Accounts`.
- Do not paste credentials into the script.
- Do not hardcode passwords, secrets, or access tokens.

## Data handled

The script may display or export tenant administration data, including environment names, environment IDs, resource names, resource IDs, current limits, desired limits, and update status.

Treat generated CSV exports and logs as internal administration data.

## Reporting issues

Do not include secrets, access tokens, tenant-private exports, or customer-identifying data in public issues.

## Disclaimer

This is a sample administration utility. Validate behavior in a limited scope before production use.

