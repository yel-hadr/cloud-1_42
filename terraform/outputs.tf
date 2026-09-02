# Consumed by `make inventory`, which writes it into inventory.yaml so
# Ansible targets whatever Terraform just built.
output "instance_public_ip" {
  description = "Elastic IP attached to the instance."
  value       = data.aws_eip.web.public_ip

  # The address is known before the association exists, so without this a
  # `terraform output` taken mid-apply could feed `make inventory` an IP that
  # nothing is answering on yet.
  depends_on = [aws_eip_association.web]
}

output "ami_id" {
  description = "Ubuntu 22.04 AMI actually selected."
  value       = data.aws_ami.ubuntu.id
}
