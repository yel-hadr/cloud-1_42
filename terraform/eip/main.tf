# The project's one stable public identity. The A records for
# youssefelhadraoui.tech point here, so this address must outlive any
# individual instance.
#
# It lives in its own root module, with its own state, precisely so that
# `make down` cannot reach it: ../ never declares the address, only an
# aws_eip_association to whatever instance currently exists. A blanket
# `terraform destroy` over there therefore has no code path to releasing
# it, and `make up` re-associates this same address instead of allocating
# a new one.
#
# Apply this directory by hand, once. It is deliberately not wired into
# `make up`.
resource "aws_eip" "web" {
  domain = "vpc"

  tags = { Name = "cloud1-eip" }

  # Second line of defence, for a `terraform destroy` run inside this
  # directory. Releasing the address means losing it - AWS hands it to
  # someone else, and every DNS record has to be rewritten.
  lifecycle {
    prevent_destroy = true
  }
}

# Copied into var.eip_allocation_id in ../variables.tf, which is how the
# main module finds this address.
output "allocation_id" {
  description = "Allocation ID to set as eip_allocation_id in the main module."
  value       = aws_eip.web.allocation_id
}

output "public_ip" {
  description = "The reserved address itself."
  value       = aws_eip.web.public_ip
}
