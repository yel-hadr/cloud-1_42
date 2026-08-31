# Consumed by `make inventory`, which writes it into inventory.yaml so
# Ansible targets whatever Terraform just built.
output "instance_public_ip" {
  description = "Elastic IP attached to the instance."
  value       = aws_eip.web.public_ip
}

output "ami_id" {
  description = "Ubuntu 22.04 AMI actually selected."
  value       = data.aws_ami.ubuntu.id
}
