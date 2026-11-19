name: Aureon Terraform Dev

on:
  workflow_dispatch:

permissions:
  id-token: write
  contents: read

jobs:
  terraform-dev:
    name: Terraform Dev - Initialize and Plan
    runs-on:
      - self-hosted
      - Linux
      - X64
      - aureon-terraform-dev

    environment: dev

    env:
      ARM_USE_OIDC: "true"
      ARM_USE_AZUREAD: "true"
      ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
      ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}

    defaults:
      run:
        working-directory: infra/terraform/environments/dev

    steps:
      - name: Checkout repository
        uses: actions/checkout@v4

      - name: Login to Azure using OIDC
        uses: azure/login@v2
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}

      - name: Install Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "1.16.5"

      - name: Terraform Init
        run: terraform init -input=false

      - name: Terraform Validate
        run: terraform validate

      - name: Terraform Plan
        run: terraform plan -input=false -no-color